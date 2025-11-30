<#
ListGitHubRepos.ps1

Robust script to list GitHub repos for one or more accounts and produce an HTML summary.
License links are resolved by querying the repository license endpoint; the script does NOT assume /LICENSE.
Fork parent license and repo links are shown inline in parentheses.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Accounts = "",

    [Parameter(Mandatory=$false)]
    [bool]$ShowProgress = $true,

    [Parameter(Mandatory=$false)]
    [switch]$SaveDebugFiles,

    [Parameter(Mandatory=$false)]
    [int]$MaxAttempts = 4,

    [Parameter(Mandatory=$false)]
    [int]$DetailRequestDelayMs = 2000,

    [Parameter(Mandatory=$false)]
    [string]$ExcludeNames = '.github',

    [Parameter(Mandatory=$false)]
    [switch]$ShowStars,

    [Parameter(Mandatory=$false)]
    [switch]$ShowForks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Paths
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$HtmlOut = Join-Path -Path $ScriptDir -ChildPath 'GitHubRepos.html'
$DebugDir = Join-Path -Path $ScriptDir -ChildPath 'repo-debug'
$LogTimestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

function Encode-Html { param([string]$Text) if ($null -eq $Text) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$Text) }

# If no accounts, create a minimal HTML and exit cleanly
if ([string]::IsNullOrWhiteSpace($Accounts)) {
    Write-Host "No accounts provided. Use -Accounts 'user1 user2' or set the Accounts parameter." -ForegroundColor Yellow
    "<!doctype html>`n<html><body><h1>No accounts provided</h1></body></html>" | Out-File -FilePath $HtmlOut -Encoding UTF8
    Write-Host ("Generated HTML: {0}" -f $HtmlOut)
    exit 0
}

# Normalize accounts input and preserve order
$Accounts = $Accounts -replace ',', ' '
$AccountList = $Accounts -split '\s+' | Where-Object { $_ -ne '' }

# Prepare debug folder if requested
if ($SaveDebugFiles) {
    try {
        if (-not (Test-Path -Path $DebugDir)) {
            New-Item -Path $DebugDir -ItemType Directory -Force | Out-Null
        }
    } catch {
        Write-Host ("Warning: could not create debug directory {0}: {1}" -f $DebugDir, $_.Exception.Message) -ForegroundColor Yellow
        $SaveDebugFiles = $false
    }
}

# --- GitHub helpers ---
function Get-GitHub {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [int]$Attempt = 1
    )
    $token = $env:GITHUB_TOKEN
    # Include topics preview in Accept so repo topics are returned when fetching details
    $acceptHeader = 'application/vnd.github.mercy-preview+json, application/vnd.github.v3+json'
    $headers = @{
        'User-Agent' = 'ListGitHubReposScript'
        'Accept'     = $acceptHeader
    }
    if ($token) { $headers['Authorization'] = "token $token" }

    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -ErrorAction Stop
    } catch {
        # Try to extract HTTP status code if available
        $status = $null
        try { if ($_.Exception.Response -ne $null) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
        if ($status -eq 403) {
            Write-Host ("GitHub returned 403 Forbidden for {0}. Check rate limits or GITHUB_TOKEN." -f $Uri) -ForegroundColor Red
            return $null
        }
        if ($Attempt -lt $MaxAttempts) {
            $wait = [math]::Min(5 * $Attempt, 30)
            Write-Host ("Request failed for {0} (attempt {1}). Retrying in {2} seconds..." -f $Uri, $Attempt, $wait) -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
            return Get-GitHub -Uri $Uri -Attempt ($Attempt + 1)
        } else {
            Write-Host ("Request failed for {0} after {1} attempts: {2}" -f $Uri, $MaxAttempts, $_.Exception.Message) -ForegroundColor Red
            return $null
        }
    }
}

function Get-GitHubPaged {
    param([Parameter(Mandatory=$true)][string]$BaseUri)
    $results = @()
    $page = 1
    while ($true) {
        $uri = "$BaseUri`?per_page=100&page=$page"
        $resp = Get-GitHub -Uri $uri
        if ($null -eq $resp) { break }

        # Detect error-like payloads
        if ($resp -is [System.Management.Automation.PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'message') {
            Write-Host ("GitHub API returned an error for {0}: {1}" -f $uri, $resp.message) -ForegroundColor Yellow
            break
        }

        $items = @($resp)
        $itemCount = ($items | Measure-Object).Count
        if ($itemCount -gt 0) { $results += $items }
        if ($itemCount -lt 100) { break }
        $page++
    }
    return $results
}

function Save-Debug {
    param([Parameter(Mandatory=$true)][string]$FileName, [Parameter(Mandatory=$true)][object]$Content)
    if (-not $SaveDebugFiles) { return }
    $path = Join-Path -Path $DebugDir -ChildPath $FileName
    try {
        $json = $null
        try { $json = $Content | ConvertTo-Json -Depth 10 -ErrorAction Stop } catch { try { $json = $Content | ConvertTo-Json -Depth 4 -ErrorAction SilentlyContinue } catch { $json = $Content | Out-String } }
        $json | Out-File -FilePath $path -Encoding UTF8
    } catch {
        Write-Host ("Warning: failed to save debug file {0}: {1}" -f $path, $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Get-ReposForAccount {
    param([Parameter(Mandatory=$true)][string]$Account)
    $base = "https://api.github.com/users/$Account/repos"
    $repos = Get-GitHubPaged -BaseUri $base
    if ($null -eq $repos) { return @() }
    return @($repos)
}

function Get-RepoDetails {
    param([Parameter(Mandatory=$true)][string]$Owner, [Parameter(Mandatory=$true)][string]$RepoName)
    $uri = "https://api.github.com/repos/$Owner/$RepoName"
    $detail = Get-GitHub -Uri $uri
    if ($null -eq $detail) {
        Write-Host ("Warning: failed to fetch details for {0}/{1}. Using summary info if available." -f $Owner, $RepoName) -ForegroundColor Yellow
        return $null
    }
    if ($detail -is [System.Management.Automation.PSCustomObject] -and $detail.PSObject.Properties.Name -contains 'message') {
        Write-Host ("Warning: GitHub returned an error for {0}/{1}: {2}" -f $Owner, $RepoName, $detail.message) -ForegroundColor Yellow
        return $null
    }
    return $detail
}

# New: resolve license link by querying the repository license endpoint (does not assume /LICENSE)
function Resolve-LicenseForRepo {
    param(
        [Parameter(Mandatory=$true)][psobject]$RepoObj
    )
    # Returns hashtable: @{ Name = 'MIT License'; Link = 'https://...' } or $null
    try {
        # If the repo object already contains license info with a name, capture it
        $licenseName = $null
        if ($null -ne $RepoObj.license) {
            if ($RepoObj.license.name) { $licenseName = $RepoObj.license.name }
            elseif ($RepoObj.license.spdx_id) { $licenseName = $RepoObj.license.spdx_id }
        }

        # Try the dedicated license endpoint: /repos/{owner}/{repo}/license
        if ($null -ne $RepoObj.full_name) {
            $parts = $RepoObj.full_name -split '/'
            if ($parts.Count -ge 2) {
                $owner = $parts[0]; $repo = $parts[1]
                $licenseEndpoint = "https://api.github.com/repos/$owner/$repo/license"
                $licResp = Get-GitHub -Uri $licenseEndpoint
                if ($null -ne $licResp -and -not ($licResp -is [string])) {
                    $licName = $null
                    try { if ($licResp.license -and $licResp.license.name) { $licName = $licResp.license.name } } catch {}
                    if (-not $licName -and $licenseName) { $licName = $licenseName }
                    $licLink = $null
                    try {
                        if ($licResp.html_url) { $licLink = $licResp.html_url }
                        elseif ($licResp.download_url) { $licLink = $licResp.download_url }
                    } catch {}
                    if ($licName -or $licLink) {
                        $out = @{}
                        $out.Name = $licName
                        $out.Link = $licLink
                        return $out
                    }
                }
            }
        }

        # Fallback: if RepoObj.license has a URL field (API), use it
        try {
            if ($null -ne $RepoObj.license -and $RepoObj.license.url) {
                $out = @{}
                $out.Name = $licenseName
                $out.Link = $RepoObj.license.url
                return $out
            }
        } catch {}

        # Final fallback: return name only if available
        try {
            if ($licenseName) {
                $out = @{}
                $out.Name = $licenseName
                $out.Link = $null
                return $out
            }
        } catch {}
    } catch {
        # ignore and return $null
    }
    return $null
}

# --- HTML generation: list repos sequentially (no account grouping) ---
function Generate-HTML {
    param([Parameter(Mandatory=$true)][hashtable]$DataByAccount, [Parameter(Mandatory=$true)][string[]]$AccountOrder)

    $html = New-Object System.Collections.Generic.List[string]
    $html.Add('<!doctype html>')
    $html.Add('<html lang="en">')
    $html.Add('<head>')
    $html.Add('  <meta charset="utf-8" />')
    $html.Add('  <meta name="viewport" content="width=device-width, initial-scale=1" />')
    $html.Add('  <title>GitHub Repositories</title>')
    $html.Add('  <style>')
    $html.Add('    body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; }')
    $html.Add('    h1 { font-size: 1.6em; }')
    $html.Add('    .repo { margin: 12px 0; }')
    $html.Add('    .meta { color: #666; font-size: 0.95em; margin-top:4px }')
    $html.Add('    .tags { margin-top:6px; font-size:0.9em; color:#2b7bb9 }')
    $html.Add('    hr { border: none; border-top: 1px solid #ddd; margin:12px 0 }')
    $html.Add('  </style>')
    $html.Add('</head>')
    $html.Add('<body>')
    $html.Add(("  <h1>GitHub Repositories</h1>"))
    $html.Add(("  <p>Generated: {0}</p>" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))

    foreach ($acct in $AccountOrder) {
        if (-not $DataByAccount.ContainsKey($acct)) { continue }
        $repos = @($DataByAccount[$acct])
        foreach ($r in $repos) {
            $name = $r.name
            $desc = if ($r.description) { Encode-Html $r.description } else { '' }
            $url = $r.html_url
            $linkText = ("{0}/{1}" -f $acct, $name)

            # fork detection
            $isFork = $false
            try { $isFork = [bool]$r.fork } catch { $isFork = $false }

            # Resolve repo license (name + link) using the new helper
            $repoLicense = Resolve-LicenseForRepo -RepoObj $r
            $repoLicenseName = $null; $repoLicenseLink = $null
            if ($null -ne $repoLicense) {
                $repoLicenseName = $repoLicense.Name
                $repoLicenseLink = $repoLicense.Link
            }

            # topics (tags)
            $topics = @()
            try { if ($null -ne $r.topics) { $topics = @($r.topics) } } catch { $topics = @() }

            # parent info for forks: prefer parent object if present; otherwise try to fetch parent details
            $parentHtml = ''
            try {
                if ($isFork) {
                    $parentObj = $null
                    if ($null -ne $r.parent) { $parentObj = $r.parent }
                    else {
                        # attempt to fetch repo details to get parent (if not present)
                        $maybe = Get-RepoDetails -Owner $acct -RepoName $name
                        if ($null -ne $maybe -and $null -ne $maybe.parent) { $parentObj = $maybe.parent }
                    }

                    if ($null -ne $parentObj -and $parentObj.full_name) {
                        $parentFull = $parentObj.full_name
                        $parentUrl = $parentObj.html_url
                        # resolve parent license via helper
                        $parentLicense = Resolve-LicenseForRepo -RepoObj $parentObj
                        $parentLicenseName = $null; $parentLicenseLink = $null
                        if ($null -ne $parentLicense) {
                            $parentLicenseName = $parentLicense.Name
                            $parentLicenseLink = $parentLicense.Link
                        }
                        if ($parentLicenseName) {
                            if ($parentLicenseLink) {
                                $parentHtml = ("Forked from <a href='{0}' target='_blank'>{1}</a> (<a href='{2}' target='_blank'>{3}</a>)" -f (Encode-Html $parentUrl), (Encode-Html $parentFull), (Encode-Html $parentLicenseLink), (Encode-Html $parentLicenseName))
                            } else {
                                $parentHtml = ("Forked from <a href='{0}' target='_blank'>{1}</a> ({2})" -f (Encode-Html $parentUrl), (Encode-Html $parentFull), (Encode-Html $parentLicenseName))
                            }
                        } else {
                            $parentHtml = ("Forked from <a href='{0}' target='_blank'>{1}</a>" -f (Encode-Html $parentUrl), (Encode-Html $parentFull))
                        }
                    }
                }
            } catch { $parentHtml = '' }

            # meta parts
            $metaParts = @()
            if ($ShowStars) { $metaParts += ("Stars: {0}" -f ($r.stargazers_count -as [int])) }
            if ($ShowForks)  { $metaParts += ("Forks: {0}" -f ($r.forks_count -as [int])) }
            if ($isFork) { $metaParts += "Fork" }
            $meta = if ((($metaParts | Measure-Object).Count) -gt 0) { $metaParts -join ' · ' } else { '' }

            # Build HTML for this repo
            $html.Add("  <div class='repo'>")

            # Repo link (URL) — link text is account/repo
            $html.Add(("    <a href='{0}' target='_blank'><strong>{1}</strong></a>" -f (Encode-Html $url), (Encode-Html $linkText)))

            # Inline license for the repo (in parentheses after the repo title), not part of the URL
            if ($repoLicenseName) {
                if ($repoLicenseLink) {
                    # Build anchor safely by concatenation to avoid nested -f issues
                    $licenseAnchor = "<a href='" + (Encode-Html $repoLicenseLink) + "' target='_blank'>" + (Encode-Html $repoLicenseName) + "</a>"
                    $html.Add(("    <span> ({0})</span>" -f $licenseAnchor))
                } else {
                    $html.Add(("    <span> ({0})</span>" -f (Encode-Html $repoLicenseName)))
                }
            }

            if ($desc) { $html.Add(("    <div class='meta'>{0}</div>" -f $desc)) }
            if ($meta) { $html.Add(("    <div class='meta'>{0}</div>" -f (Encode-Html $meta))) }
            if ($parentHtml) { $html.Add(("    <div class='meta'>{0}</div>" -f $parentHtml)) }
            if ((($topics | Measure-Object).Count) -gt 0) {
                $html.Add(("    <div class='tags'><em>{0}</em></div>" -f (Encode-Html (($topics -join ', ')))) )
            }

            $html.Add("  </div>")
            $html.Add("  <hr />")
        }
    }

    $html.Add('</body>')
    $html.Add('</html>')

    try {
        $html -join "`n" | Out-File -FilePath $HtmlOut -Encoding UTF8
        Write-Host ("Generated HTML: {0}" -f $HtmlOut)
    } catch {
        Write-Host ("Failed to write HTML file {0}: {1}" -f $HtmlOut, $_.Exception.Message) -ForegroundColor Red
    }
}

# --- Main processing (defensive) ---
$allData = @{}
$totalAccounts = ($AccountList | Measure-Object).Count
$acctIndex = 0

foreach ($acct in $AccountList) {
    $acctIndex++
    if ($ShowProgress) {
        $percent = 0
        if ($totalAccounts -gt 0) { $percent = [int](($acctIndex - 1) / $totalAccounts * 100) }
        Write-Progress -Activity "Fetching accounts" -Status ("Processing {0} ({1}/{2})" -f $acct, $acctIndex, $totalAccounts) -PercentComplete $percent
    }

    Write-Host ("Processing account: {0}" -f $acct) -ForegroundColor Cyan

    $repos = @()
    try {
        $repos = Get-ReposForAccount -Account $acct
    } catch {
        Write-Host ("Warning: unexpected error fetching repos for {0}: {1}" -f $acct, $_.Exception.Message) -ForegroundColor Yellow
        $repos = @()
    }

    # Ensure repos is an array and count safely
    $repos = @($repos)
    $repoCount = ($repos | Measure-Object).Count
    if ($repoCount -eq 0) {
        Write-Host ("No repositories returned for {0}. Skipping." -f $acct) -ForegroundColor Yellow
        $allData[$acct] = @()
        continue
    }

    # Exclude filter
    if ($ExcludeNames) {
        $excludes = $ExcludeNames -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $excludesCount = ($excludes | Measure-Object).Count
        if ($excludesCount -gt 0) {
            $repos = @($repos | Where-Object {
                $keep = $true
                foreach ($ex in $excludes) { if ($_.name -like "*$ex*") { $keep = $false; break } }
                $keep
            })
            $repoCount = ($repos | Measure-Object).Count
            if ($repoCount -eq 0) {
                Write-Host ("No repositories left after filtering for {0}. Skipping." -f $acct) -ForegroundColor Yellow
                $allData[$acct] = @()
                continue
            }
        }
    }

    if ($SaveDebugFiles) {
        $file = ("{0}_repos_{1}.json" -f $acct, $LogTimestamp)
        Save-Debug -FileName $file -Content $repos
    }

    # Fetch details per repo (ensures topics and parent are present)
    $detailed = New-Object System.Collections.ArrayList
    $repoIndex = 0
    foreach ($r in $repos) {
        $repoIndex++
        if ($ShowProgress) {
            $percentRepo = 0
            if ($repoCount -gt 0) { $percentRepo = [int](($repoIndex - 1) / $repoCount * 100) }
            Write-Progress -Activity ("Fetching repos for {0}" -f $acct) -Status ("Repo {0}/{1}: {2}" -f $repoIndex, $repoCount, $r.name) -PercentComplete $percentRepo
        }

        $detail = $null
        try {
            $detail = Get-RepoDetails -Owner $acct -RepoName $r.name
        } catch {
            Write-Host ("Warning: unexpected error fetching details for {0}/{1}: {2}" -f $acct, $r.name, $_.Exception.Message) -ForegroundColor Yellow
            $detail = $null
        }

        if ($null -ne $detail) {
            if ($null -eq $detail.topics) { $detail | Add-Member -NotePropertyName topics -NotePropertyValue @() -Force }
            [void]$detailed.Add($detail)
            if ($SaveDebugFiles) {
                $safeName = ($acct + '_' + $r.name) -replace '[\\/:*?"<>|]', '_'
                Save-Debug -FileName ("{0}_{1}.json" -f $safeName, $LogTimestamp) -Content $detail
            }
        } else {
            if ($null -eq $r.topics) { $r | Add-Member -NotePropertyName topics -NotePropertyValue @() -Force }
            [void]$detailed.Add($r)
        }

        if ($DetailRequestDelayMs -gt 0) { Start-Sleep -Milliseconds $DetailRequestDelayMs }
    }

    $allData[$acct] = $detailed
}

if ($ShowProgress) { Write-Progress -Activity "Done" -Completed }

try { Generate-HTML -DataByAccount $allData -AccountOrder $AccountList } catch { Write-Host ("Failed to generate HTML: {0}" -f $_.Exception.Message) -ForegroundColor Red }

# Final summary
$hadAny = $false
foreach ($k in $allData.Keys) {
    if ((($allData[$k] | Measure-Object).Count) -gt 0) { $hadAny = $true; break }
}

if ($hadAny) {
    Write-Host "Completed: repositories fetched and HTML generated." -ForegroundColor Green
} else {
    Write-Host "Completed: no repositories found or API calls failed (see messages above)." -ForegroundColor Yellow
}

exit 0
