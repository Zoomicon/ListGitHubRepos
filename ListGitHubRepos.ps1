<#
.SYNOPSIS
  ListGitHubRepos.ps1
.DESCRIPTION
  Fetches public repositories for one or more GitHub accounts and generates GitHubRepos.html.
  Uses GITHUB_TOKEN from environment if set.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Accounts,

    [switch]$HideForks,
    [switch]$SkipDotPrefix,
    [switch]$SaveDebugFiles,

    [int]$MaxAttempts = 4,

    [string]$ExcludeNames = ".github",
    [string]$ItalicNames = ".github",

    [switch]$ShowStars,
    [switch]$ShowForks,
    [string]$StarsLabel = "Stars:",
    [string]$ForksLabel = "Forks:"
)

if ($env:GH_MAX_RETRIES -and $env:GH_MAX_RETRIES.Trim() -ne '') {
    try { $MaxAttempts = [int]$env:GH_MAX_RETRIES } catch {}
}

if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
elseif ($MaxAttempts -gt 20) { $MaxAttempts = 20 }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Diagnostic { param([string]$Message) Write-Host $Message }
function Write-DiagnosticWarning { param([string]$Message) Write-Warning $Message }
function Write-DiagnosticError { param([string]$Message) Write-Error $Message }

$headers = @{ 'User-Agent' = 'ListGitHubReposScript' }
if ($env:GITHUB_TOKEN -and $env:GITHUB_TOKEN.Trim() -ne '') {
    $headers['Authorization'] = "token $($env:GITHUB_TOKEN.Trim())"
} else {
    Write-Diagnostic "No GITHUB_TOKEN set (unauthenticated requests)"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$outputHtml = Join-Path $scriptDir 'GitHubRepos.html'
$debugDir = if ($env:DEBUG_DIR -and $env:DEBUG_DIR.Trim() -ne '') { $env:DEBUG_DIR } else { Join-Path $scriptDir 'repo-debug' }

if ($SaveDebugFiles) {
    if (-not (Test-Path $debugDir)) { New-Item -Path $debugDir -ItemType Directory | Out-Null }
}

function Save-DebugResponse {
    param([string]$Prefix, [string]$Body, [hashtable]$Hdrs = $null, [int]$StatusCode = $null)
    if (-not $SaveDebugFiles) { return }
    try {
        $safePrefix = ($Prefix -replace '[\\/:*?""<>| ]','_')
        $time = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $fileBase = Join-Path $debugDir ("{0}_{1}" -f $safePrefix, $time)
        $hdrFile = $fileBase + ".headers.txt"
        $bodyFile = $fileBase + ".body.txt"
        if ($Hdrs) {
            $out = @()
            if ($StatusCode) { $out += "StatusCode: $StatusCode" }
            foreach ($k in $Hdrs.Keys) { $out += ("{0}: {1}" -f $k, $Hdrs[$k]) }
            $out | Out-File -FilePath $hdrFile -Encoding UTF8
        }
        $Body | Out-File -FilePath $bodyFile -Encoding UTF8
        Write-Diagnostic ("Saved debug files: " + (Split-Path $hdrFile -Leaf) + ", " + (Split-Path $bodyFile -Leaf))
    } catch {
        Write-DiagnosticWarning "Failed to save debug response."
    }
}

function Headers-ToHashtable {
    param([object]$Headers)
    $ht = @{}
    if ($null -eq $Headers) { return $ht }
    try {
        foreach ($name in $Headers.Keys) {
            $ht[$name] = $Headers[$name]
        }
    } catch {
        try {
            $Headers | Get-Member -MemberType NoteProperty | ForEach-Object {
                $n = $_.Name
                $ht[$n] = $Headers.$n
            }
        } catch {}
    }
    return $ht
}

function Invoke-GitHubJson {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$DebugPrefix = "request"
    )

    $maxAttempts = if ($MaxAttempts -and ($MaxAttempts -is [int])) { $MaxAttempts } else { 4 }
    $attempt = 0
    $baseDelaySeconds = 1
    $lastSeenRemaining = $null

    while ($true) {
        $attempt++
        try {
            $resp = Invoke-RestMethod -Uri $Url -Headers $headers -Method Get -ErrorAction Stop
            try {
                $hdrResp = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction SilentlyContinue
                if ($hdrResp -ne $null) {
                    $hdrs = Headers-ToHashtable $hdrResp.Headers
                    if ($hdrs['X-RateLimit-Remaining']) { $lastSeenRemaining = $hdrs['X-RateLimit-Remaining'] }
                }
            } catch {}
            return @{ Result = $resp; Remaining = $lastSeenRemaining }
        } catch {
            # Enhanced extraction: try to read response from the exception, then fallback to Invoke-WebRequest
            $webResp = $null
            $statusCode = $null
            $hdrs = $null
            $body = $null

            try {
                $ex = $_.Exception
                if ($ex -and $ex.Response) {
                    $resp = $ex.Response
                    try { $statusCode = [int]$resp.StatusCode } catch {}
                    try { $hdrs = Headers-ToHashtable $resp.Headers } catch {}
                    try {
                        $stream = $resp.GetResponseStream()
                        if ($stream) {
                            $sr = New-Object System.IO.StreamReader($stream)
                            $body = $sr.ReadToEnd()
                            $sr.Close()
                        }
                    } catch {}
                }
            } catch {}

            if (-not $body) {
                try {
                    $webResp = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction SilentlyContinue
                    if ($webResp -ne $null) {
                        try { $statusCode = [int]$webResp.StatusCode } catch {}
                        $hdrs = Headers-ToHashtable $webResp.Headers
                        $body = $webResp.Content
                    }
                } catch {
                    $webResp = $null
                }
            }

            Save-DebugResponse -Prefix $DebugPrefix -Body ($body -as [string]) -Hdrs $hdrs -StatusCode $statusCode

            if ($statusCode) {
                Write-Diagnostic ("GitHub API returned HTTP $statusCode for $Url")
            } else {
                Write-Diagnostic ("GitHub API returned an error for $Url (no HTTP status available)")
            }

            $retryAfter = $null
            $rateReset = $null
            try {
                if ($hdrs['Retry-After']) { $retryAfter = [int]$hdrs['Retry-After'] }
                if ($hdrs['X-RateLimit-Reset']) { $rateReset = [int]$hdrs['X-RateLimit-Reset'] }
                if ($hdrs['X-RateLimit-Remaining'] -and $hdrs['X-RateLimit-Remaining'] -eq '0' -and $rateReset) {
                    $nowEpoch = [int](Get-Date -UFormat %s)
                    $wait = $rateReset - $nowEpoch
                    if ($wait -gt 0) {
                        Write-Diagnostic "Rate limit exhausted; waiting $wait seconds until reset (epoch $rateReset). Attempt $attempt of $maxAttempts."
                        Start-Sleep -Seconds ($wait + 2)
                    }
                }
            } catch {}

            if ($retryAfter -ne $null -and $retryAfter -gt 0) {
                Write-Diagnostic "Server asked to retry after $retryAfter seconds. Attempt $attempt of $maxAttempts."
                Start-Sleep -Seconds $retryAfter
            } else {
                if ($attempt -lt $maxAttempts) {
                    $delay = [math]::Min(300, $baseDelaySeconds * [math]::Pow(2, $attempt - 1))
                    Write-Diagnostic "HTTP $statusCode received. Backing off $delay seconds. Attempt $attempt of $maxAttempts."
                    Start-Sleep -Seconds $delay
                }
            }

            if ($attempt -ge $maxAttempts) {
                throw "HTTP $statusCode returned for $Url after $attempt attempts."
            } else {
                continue
            }
        }
    }
}

# Normalize accounts list and ensure array
$accountList = @($Accounts -split '[, ]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
if (@($accountList).Count -eq 0) {
    Write-DiagnosticError "No valid accounts provided in -Accounts parameter."
    exit 2
}

# Parse exclude names into an array (case-insensitive)
$excludedList = @()
if ($ExcludeNames -and $ExcludeNames.Trim() -ne "") {
    $excludedList = @($ExcludeNames -split '[, ]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) | ForEach-Object { $_.ToLowerInvariant() }
}

# Parse italic names into an array (case-insensitive)
$italicList = @()
if ($ItalicNames -and $ItalicNames.Trim() -ne "") {
    $italicList = @($ItalicNames -split '[, ]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) | ForEach-Object { $_.ToLowerInvariant() }
}

# Collect repo entries
$allRepos = @()
$lastRemaining = $null

try { Check-GlobalRateLimit | Out-Null } catch {}

foreach ($acct in $accountList) {
    Write-Host "Fetching repos for: $acct"

    try {
        $global = Check-GlobalRateLimit
        if ($global -and $global.Remaining -and $global.Remaining -eq '0' -and $global.Reset) {
            $nowEpoch = [int](Get-Date -UFormat %s)
            $wait = [int]$global.Reset - $nowEpoch
            if ($wait -gt 0) {
                Write-Diagnostic "Global rate limit exhausted before fetching $acct; waiting $wait seconds until reset."
                Start-Sleep -Seconds ($wait + 2)
            }
        }
    } catch {}

    $listUrl = "https://api.github.com/users/$acct/repos?per_page=100"
    try {
        $reposResult = Invoke-GitHubJson -Url $listUrl -DebugPrefix ("list_{0}" -f $acct)
        if ($null -eq $reposResult) { throw "No response for $acct" }
        $repos = $reposResult.Result
        $lastRemaining = $reposResult.Remaining
    } catch {
        Write-DiagnosticWarning "Warning: Account '$acct' not found or inaccessible (HTTP error)."
        Write-Host ""
        continue
    }

    if ($null -eq $repos) {
        Write-DiagnosticWarning "No repository list returned for $acct; skipping."
        Write-Host ""
        continue
    }

    # Ensure $repos is an array-like collection
    if (-not ($repos -is [System.Collections.IEnumerable]) -or ($repos -is [string])) {
        $repos = @($repos)
    }

    if (@($repos).Count -eq 0) {
        Write-DiagnosticWarning "Repository list for $acct is empty; skipping."
        Write-Host ""
        continue
    }

    if ($SaveDebugFiles) {
        try {
            $listFile = Join-Path $debugDir ("list_{0}.json" -f $acct)
            $repos | ConvertTo-Json -Depth 10 | Out-File -FilePath $listFile -Encoding UTF8
        } catch {}
    }

    foreach ($r in $repos) {
        # Normalize repo name for checks
        $repoName = $r.name

        # Skip exact-name exclusions (case-insensitive)
        if (@($excludedList).Count -gt 0 -and (@($excludedList) -contains $repoName.ToLowerInvariant())) {
            Write-Diagnostic ("Skipping excluded repo by name: " + $repoName)
            continue
        }

        if ($SkipDotPrefix -and $repoName.StartsWith('.')) { continue }
        if ($HideForks -and $r.fork) { continue }

        $owner = $r.owner.login

        # Only fetch details when necessary: forks (to get parent) or missing license info
        $detail = $r
        $needDetail = $false
        if ($r.fork) { $needDetail = $true }
        if (-not $r.license) { $needDetail = $true }

        if ($needDetail) {
            $encOwner = [uri]::EscapeDataString($owner)
            $encRepo  = [uri]::EscapeDataString($repoName)
            $detailUrl = "https://api.github.com/repos/$encOwner/$encRepo"

            try {
                $detailResult = Invoke-GitHubJson -Url $detailUrl -DebugPrefix ("detail_{0}_{1}" -f $owner, $repoName)
                $detail = $detailResult.Result
            } catch {
                $status = $null
                try {
                    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                        $status = [int]$_.Exception.Response.StatusCode
                    }
                } catch {}

                if ($status -eq 404) {
                    Write-Diagnostic ("Repo not found or inaccessible (404): " + "$owner/$repoName. Using list data.")
                } elseif ($status -ne $null) {
                    Write-DiagnosticWarning ("Failed to fetch details for $owner/$repoName (HTTP $status). Using list data.")
                } else {
                    Write-DiagnosticWarning ("Failed to fetch details for $owner/$repoName. Using list data.")
                }

                $detail = $r
            }
        }

        $parentObj = $null
        if ($detail -and $detail.PSObject.Properties.Name -contains 'parent') {
            $parentObj = $detail.parent
        }

        $licenseObj = $null
        if ($detail -and $detail.PSObject.Properties.Name -contains 'license') {
            $licenseObj = $detail.license
        }

        $allRepos += [PSCustomObject]@{
            Account      = $acct
            Owner        = $owner
            Name         = $repoName
            FullName     = $detail.full_name
            HtmlUrl      = $detail.html_url
            Description  = $detail.description
            Fork         = [bool]$detail.fork
            License      = $licenseObj
            Parent       = $parentObj
            CreatedAt    = $detail.created_at
            UpdatedAt    = $detail.updated_at
            Stargazers   = $detail.stargazers_count
            ForksCount   = $detail.forks_count
        }
    }

    if ($lastRemaining -ne $null) { Write-Diagnostic ("Account ${acct}: last seen X-RateLimit-Remaining = $lastRemaining") }

    Write-Host ""
}

# Generate HTML
$sb = New-Object System.Text.StringBuilder
$append = { param($s) [void]$sb.AppendLine($s) }

$append.Invoke('<!doctype html>')
$append.Invoke('<html lang="en">')
$append.Invoke('<head>')
$append.Invoke('  <meta charset="utf-8">')
$append.Invoke('  <meta name="viewport" content="width=device-width,initial-scale=1">')
$append.Invoke('  <title>GitHub Repos</title>')
$append.Invoke('  <style>')
$append.Invoke('    body{font-family:Arial,Helvetica,sans-serif;margin:20px;background:#fff;color:#111}')
$append.Invoke('    .repo{border-bottom:1px solid #ddd;padding:12px 0}')
$append.Invoke('    .title{font-size:1.1em;font-weight:600}')
$append.Invoke('    .meta{color:#555;font-size:0.95em;margin-top:6px}')
$append.Invoke('    .stat{margin-top:8px;font-size:0.95em}')
$append.Invoke('    .stat strong{display:inline-block;width:70px}')
$append.Invoke('    em.desc{font-style:italic}')
$append.Invoke('  </style>')
$append.Invoke('</head>')
$append.Invoke('<body>')
$append.Invoke("  <h1>GitHub Repositories</h1>")
$append.Invoke("  <p>Generated: $(Get-Date -Format 'u')</p>")

if (@($allRepos).Count -eq 0) {
    $append.Invoke('  <p>No repositories found for the provided accounts.</p>')
} else {
    foreach ($repo in $allRepos | Sort-Object -Property Account,FullName) {
        $append.Invoke('  <div class="repo">')
        $append.Invoke("    <div class='title'><a href='$($repo.HtmlUrl)'>$($repo.FullName)</a></div>")

        if ($repo.Description) {
            $descText = [System.Web.HttpUtility]::HtmlEncode($repo.Description)
            if (@($italicList).Count -gt 0 -and (@($italicList) -contains $repo.Name.ToLowerInvariant())) {
                $append.Invoke("    <div class='meta'><em class='desc'>$descText</em></div>")
            } else {
                $append.Invoke("    <div class='meta'>$descText</div>")
            }
        }

        if ($null -ne $repo.License) {
            $licText = ''
            if ($repo.License.spdx_id -and $repo.License.spdx_id -ne 'NOASSERTION') { $licText = $repo.License.spdx_id }
            elseif ($repo.License.name) { $licText = $repo.License.name }
            if ($licText -and $licText.Trim() -ne '') {
                $append.Invoke("    <div class='meta'><strong>License:</strong> $([System.Web.HttpUtility]::HtmlEncode($licText))</div>")
            } else {
                $append.Invoke("    <div class='meta'><strong>License:</strong> (none)</div>")
            }
        }

        if ($repo.Fork -and $null -ne $repo.Parent) {
            $parentFull = $repo.Parent.full_name
            $parentLicText = ''
            if ($null -ne $repo.Parent.license) {
                if ($repo.Parent.license.spdx_id -and $repo.Parent.license.spdx_id -ne 'NOASSERTION') { $parentLicText = $repo.Parent.license.spdx_id }
                elseif ($repo.Parent.license.name) { $parentLicText = $repo.Parent.license.name }
            }
            if ($parentLicText -and $parentLicText.Trim() -ne '') {
                $append.Invoke("    <div class='meta'><strong>Forked from:</strong> $([System.Web.HttpUtility]::HtmlEncode($parentFull)) ($([System.Web.HttpUtility]::HtmlEncode($parentLicText)))</div>")
            } else {
                $append.Invoke("    <div class='meta'><strong>Forked from:</strong> $([System.Web.HttpUtility]::HtmlEncode($parentFull))</div>")
            }
        }

        if ($ShowStars) {
            $starsVal = if ($repo.Stargazers -ne $null) { $repo.Stargazers } else { 0 }
            $append.Invoke("    <div class='stat'><strong>$([System.Web.HttpUtility]::HtmlEncode($StarsLabel))</strong>$([System.Web.HttpUtility]::HtmlEncode($starsVal))</div>")
        }

        if ($ShowForks) {
            $forksVal = if ($repo.ForksCount -ne $null) { $repo.ForksCount } else { 0 }
            $append.Invoke("    <div class='stat'><strong>$([System.Web.HttpUtility]::HtmlEncode($ForksLabel))</strong>$([System.Web.HttpUtility]::HtmlEncode($forksVal))</div>")
        }

        $append.Invoke('  </div>')
    }
}

$append.Invoke('</body>')
$append.Invoke('</html>')

try {
    $sb.ToString() | Out-File -FilePath $outputHtml -Encoding UTF8
    Write-Host "Generated: $outputHtml"
    exit 0
} catch {
    Write-DiagnosticError "Failed to write output HTML: $($_.Exception.Message)"
    exit 3
}