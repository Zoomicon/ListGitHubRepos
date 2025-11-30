<#
.SYNOPSIS
  ListGitHubRepos.ps1
.DESCRIPTION
  Fetches public repositories for one or more GitHub accounts and generates GitHubRepos.html.
  - Uses the environment variable GITHUB_TOKEN for authenticated requests if present.
  - Parameters:
      -Accounts <string>         Comma- or space-separated list of GitHub accounts (required).
      -HideForks                 Skip forked repositories in the output.
      -SkipDotPrefix             Skip repositories whose names start with a dot.
      -SaveDebugFiles            Save raw JSON responses into a repo-debug folder for inspection.
      -MaxAttempts <int>         Number of attempts for API calls (default 4).
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Accounts,

    [switch]$HideForks,
    [switch]$SkipDotPrefix,
    [switch]$SaveDebugFiles,

    [int]$MaxAttempts = 4
)

# Allow GH_MAX_RETRIES env var to override the parameter if set
if ($env:GH_MAX_RETRIES -and $env:GH_MAX_RETRIES.Trim() -ne '') {
    try { $MaxAttempts = [int]$env:GH_MAX_RETRIES } catch {}
}

# Bounds check
if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
elseif ($MaxAttempts -gt 20) { $MaxAttempts = 20 }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Diagnostic wrappers
function Write-Diagnostic {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host $Message
    Write-Host ""
}
function Write-DiagnosticWarning {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Warning $Message
    Write-Host ""
}
function Write-DiagnosticError {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Error $Message
    Write-Host ""
}

# Prepare headers (use GITHUB_TOKEN if present)
$headers = @{ 'User-Agent' = 'ListGitHubReposScript' }
if ($env:GITHUB_TOKEN -and $env:GITHUB_TOKEN.Trim() -ne '') {
    $headers['Authorization'] = "token $($env:GITHUB_TOKEN.Trim())"
}

# Output paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$outputHtml = Join-Path $scriptDir 'GitHubRepos.html'
$debugDir = Join-Path $scriptDir 'repo-debug'

if ($SaveDebugFiles) {
    if (-not (Test-Path $debugDir)) {
        New-Item -Path $debugDir -ItemType Directory | Out-Null
    }
}

# Helper: save response body and headers for debugging
function Save-DebugResponse {
    param(
        [Parameter(Mandatory=$true)][string]$Prefix,
        [Parameter(Mandatory=$true)][string]$Body,
        [hashtable]$Hdrs = $null,
        [int]$StatusCode = $null
    )
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

# Helper: convert header collection to hashtable safely
function Headers-ToHashtable {
    param([object]$Headers)
    $ht = @{}
    if ($null -eq $Headers) { return $ht }
    try {
        foreach ($name in $Headers.Keys) {
            $ht[$name] = $Headers[$name]
        }
    } catch {
        # best-effort fallback
        try {
            $Headers | Get-Member -MemberType NoteProperty | ForEach-Object {
                $n = $_.Name
                $ht[$n] = $Headers.$n
            }
        } catch {}
    }
    return $ht
}

# Helper: check global rate limit and optionally wait until reset
function Check-GlobalRateLimit {
    try {
        $rlResp = Invoke-WebRequest -Uri 'https://api.github.com/rate_limit' -Headers $headers -Method Get -ErrorAction SilentlyContinue
        if ($null -eq $rlResp) {
            Write-DiagnosticWarning "Could not fetch global rate limit (no response)."
            return $null
        }

        $hdrs = Headers-ToHashtable $rlResp.Headers
        $coreRem = $hdrs['X-RateLimit-Remaining']
        $coreLimit = $hdrs['X-RateLimit-Limit']
        $coreReset = $hdrs['X-RateLimit-Reset']
        $retryAfter = $hdrs['Retry-After']

        $parts = @()
        if ($coreRem -and $coreLimit) { $parts += "remaining=$coreRem/$coreLimit" }
        elseif ($coreLimit) { $parts += "limit=$coreLimit" }
        if ($coreReset) {
            $nowEpoch = [int](Get-Date -UFormat %s)
            $wait = [int]$coreReset - $nowEpoch
            if ($wait -lt 0) { $wait = 0 }
            $parts += "reset_epoch=$coreReset; in ${wait}s"
        }
        if ($retryAfter) { $parts += "retry_after=${retryAfter}s" }
        if ($parts.Count -gt 0) { Write-Diagnostic ("Global rate: " + ($parts -join " ; ")) }

        # If remaining is zero, wait until reset (small safety margin)
        if ($coreRem -and ($coreRem -eq '0') -and $coreReset) {
            $nowEpoch = [int](Get-Date -UFormat %s)
            $wait = [int]$coreReset - $nowEpoch
            if ($wait -gt 0) {
                Write-Diagnostic ("Global rate limit exhausted; waiting $wait seconds until reset (epoch $coreReset).")
                Start-Sleep -Seconds ($wait + 2)
            }
        }

        # Try to parse JSON body for additional info (not required)
        return @{
            Remaining = $coreRem
            Limit = $coreLimit
            Reset = $coreReset
            RetryAfter = $retryAfter
            Headers = $hdrs
        }
    } catch {
        Write-DiagnosticWarning "Could not fetch global rate limit."
        return $null
    }
}

# Unified API caller: prefer Invoke-RestMethod for JSON, but capture headers and bodies on error
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
            # Use Invoke-RestMethod for JSON parsing
            $resp = Invoke-RestMethod -Uri $Url -Headers $headers -Method Get -ErrorAction Stop
            # If successful, we don't have headers from RestMethod; fetch headers with a lightweight webrequest
            try {
                $hdrResp = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction SilentlyContinue
                if ($hdrResp -ne $null) {
                    $hdrs = Headers-ToHashtable $hdrResp.Headers
                    if ($hdrs['X-RateLimit-Remaining']) { $lastSeenRemaining = $hdrs['X-RateLimit-Remaining'] }
                }
            } catch {}
            return @{ Result = $resp; Remaining = $lastSeenRemaining }
        } catch {
            # If Invoke-RestMethod failed, try to get the response object to inspect headers/body
            try {
                $webResp = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction SilentlyContinue
            } catch {
                $webResp = $null
            }

            if ($webResp -ne $null) {
                $statusCode = $null
                try { $statusCode = [int]$webResp.StatusCode } catch {}
                $hdrs = Headers-ToHashtable $webResp.Headers
                if ($hdrs['X-RateLimit-Remaining']) { $lastSeenRemaining = $hdrs['X-RateLimit-Remaining'] }

                # Save body and headers for debugging
                $body = $webResp.Content
                Save-DebugResponse -Prefix $DebugPrefix -Body ($body -as [string]) -Hdrs $hdrs -StatusCode $statusCode

                # Log preview
                if ($body) {
                    Write-Diagnostic ("GitHub API returned HTTP $statusCode for $Url")
                    $preview = $body.Substring(0,[Math]::Min(800,$body.Length))
                    $preview -split "`n" | ForEach-Object { Write-Host $_ }
                    Write-Host ""
                } else {
                    Write-Diagnostic ("GitHub API returned HTTP $statusCode for $Url (no body)")
                }

                # Honor Retry-After or X-RateLimit-Reset if present
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
            } else {
                # No web response object; treat as network error and back off
                if ($attempt -lt $maxAttempts) {
                    $delay = [math]::Min(300, $baseDelaySeconds * [math]::Pow(2, $attempt - 1))
                    Write-Diagnostic "Network error calling GitHub API: $($_.Exception.Message). Backing off $delay seconds. Attempt $attempt of $maxAttempts."
                    Start-Sleep -Seconds $delay
                    continue
                } else {
                    throw $_
                }
            }
        }
    }
}

# Normalize accounts list and ensure array
$accountList = @($Accounts -split '[, ]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
if ($accountList.Count -eq 0) {
    Write-DiagnosticError "No valid accounts provided in -Accounts parameter."
    exit 2
}

# Collect repo entries
$allRepos = @()
$lastRemaining = $null

# Initial global check (tolerant)
try { Check-GlobalRateLimit | Out-Null } catch {}

foreach ($acct in $accountList) {
    Write-Host "Fetching repos for: $acct"

    # Check global rate limit before each account (best-effort)
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

    # Defensive: ensure $repos is an array
    if ($null -eq $repos) {
        Write-DiagnosticWarning "No repository list returned for $acct; skipping."
        Write-Host ""
        continue
    }
    if (-not ($repos -is [System.Collections.IEnumerable])) {
        # Single-object response; wrap into array
        $repos = @($repos)
    }

    if ($SaveDebugFiles) {
        try {
            $listFile = Join-Path $debugDir ("list_{0}.json" -f $acct)
            $repos | ConvertTo-Json -Depth 10 | Out-File -FilePath $listFile -Encoding UTF8
        } catch {}
    }

    foreach ($r in $repos) {
        if ($SkipDotPrefix -and $r.name.StartsWith('.')) { continue }
        if ($HideForks -and $r.fork) { continue }

        $owner = $r.owner.login
        $repoName = $r.name
        $detailUrl = "https://api.github.com/repos/$owner/$repoName"
        try {
            $detailResult = Invoke-GitHubJson -Url $detailUrl -DebugPrefix ("detail_{0}_{1}" -f $owner, $repoName)
            $detail = $detailResult.Result
        } catch {
            Write-DiagnosticWarning "Warning: Failed to fetch details for $owner/$repoName. Using list data and continuing."
            $detail = $r
        }

        if ($SaveDebugFiles) {
            try {
                $safeName = ($owner + '_' + $repoName) -replace '[\\/:*?""<>| ]','_'
                $detailFile = Join-Path $debugDir ("detail_{0}.json" -f $safeName)
                $detail | ConvertTo-Json -Depth 20 | Out-File -FilePath $detailFile -Encoding UTF8
            } catch {}
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

    # Print per-account rate status if available
    if ($lastRemaining) {
        Write-Diagnostic ("Account ${acct}: last seen X-RateLimit-Remaining = $lastRemaining")
    }

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
$append.Invoke('    .meta{color:#555;font-size:0.9em;margin-top:6px}')
$append.Invoke('  </style>')
$append.Invoke('</head>')
$append.Invoke('<body>')
$append.Invoke("  <h1>GitHub Repositories</h1>")
$append.Invoke("  <p>Generated: $(Get-Date -Format 'u')</p>")

if ($allRepos.Count -eq 0) {
    $append.Invoke('  <p>No repositories found for the provided accounts.</p>')
} else {
    foreach ($repo in $allRepos | Sort-Object -Property Account,FullName) {
        $append.Invoke('  <div class="repo">')
        $append.Invoke("    <div class='title'><a href='$($repo.HtmlUrl)'>$($repo.FullName)</a></div>")
        if ($repo.Description) {
            $desc = [System.Web.HttpUtility]::HtmlEncode($repo.Description)
            $append.Invoke("    <div class='meta'>$desc</div>")
        }

        if ($null -ne $repo.License) {
            $licText = ''
            if ($repo.License.spdx_id -and $repo.License.spdx_id -ne 'NOASSERTION') {
                $licText = $repo.License.spdx_id
            } elseif ($repo.License.name) {
                $licText = $repo.License.name
            }
            if ($licText -and $licText.Trim() -ne '') {
                $append.Invoke("    <div class='meta'><strong>License:</strong> $([System.Web.HttpUtility]::HtmlEncode($licText))</div>")
            }
        }

        if ($repo.Fork -and $null -ne $repo.Parent) {
            $parentFull = $repo.Parent.full_name
            $parentLicText = $null
            if ($null -ne $repo.Parent.license) {
                if ($repo.Parent.license.spdx_id -and $repo.Parent.license.spdx_id -ne 'NOASSERTION') {
                    $parentLicText = $repo.Parent.license.spdx_id
                } elseif ($repo.Parent.license.name) {
                    $parentLicText = $repo.Parent.license.name
                }
            }

            if ($parentLicText -and $parentLicText.Trim() -ne '') {
                $append.Invoke("    <div class='meta'><strong>Forked from:</strong> $([System.Web.HttpUtility]::HtmlEncode($parentFull)) (License: $([System.Web.HttpUtility]::HtmlEncode($parentLicText)))</div>")
            } else {
                $append.Invoke("    <div class='meta'><strong>Forked from:</strong> $([System.Web.HttpUtility]::HtmlEncode($parentFull))</div>")
            }
        }

        $metaParts = @()
        if ($repo.Stargazers -ne $null) { $metaParts += "Stars: $($repo.Stargazers)" }
        if ($repo.ForksCount -ne $null) { $metaParts += "Forks: $($repo.ForksCount)" }
        if ($metaParts.Count -gt 0) {
            $append.Invoke("    <div class='meta'>"+([System.Web.HttpUtility]::HtmlEncode(($metaParts -join ' - ')))+"</div>")
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
