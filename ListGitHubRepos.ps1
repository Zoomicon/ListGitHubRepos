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
.EXAMPLE
  .\ListGitHubRepos.ps1 -Accounts "octocat, microsoft" -HideForks -SaveDebugFiles -MaxAttempts 6
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

# Diagnostic wrappers: print message then a single blank line
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

function Invoke-GitHubApi {
    param([Parameter(Mandatory=$true)][string]$Url)

    # Use the script-level MaxAttempts (fallback to 4 if somehow unset)
    $maxAttempts = if ($MaxAttempts -and ($MaxAttempts -is [int])) { $MaxAttempts } else { 4 }
    $attempt = 0
    $baseDelaySeconds = 1

    while ($true) {
        $attempt++
        # First try a non-throwing request so we always get headers when the server responds
        try {
            $webResp = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction SilentlyContinue
        } catch {
            # Network-level failure (DNS, TLS, etc.) — fall through to exception handling below
            $webResp = $null
        }

        # If we got a response object, inspect status and headers
        if ($null -ne $webResp) {
            # Normalize status code to int if possible
            $statusCode = $null
            try { $statusCode = [int]$webResp.StatusCode } catch { $statusCode = $null }

            # Always log rate headers when present
            if ($webResp.Headers) {
                $limit = $webResp.Headers.'X-RateLimit-Limit'
                $remaining = $webResp.Headers.'X-RateLimit-Remaining'
                $reset = $webResp.Headers.'X-RateLimit-Reset'
                $retryAfter = $webResp.Headers.'Retry-After'
                if ($limit -or $remaining -or $reset -or $retryAfter) {
                    $parts = @()
                    if ($remaining -and $limit) { $parts += "remaining=$remaining/$limit" }
                    elseif ($limit) { $parts += "limit=$limit" }
                    elseif ($remaining) { $parts += "remaining=$remaining" }
                    if ($reset) {
                        $nowEpoch = [int](Get-Date -UFormat %s)
                        $wait = [int]$reset - $nowEpoch
                        if ($wait -lt 0) { $wait = 0 }
                        $parts += "reset_epoch=$reset; in ${wait}s"
                    }
                    if ($retryAfter) { $parts += "retry_after=${retryAfter}s" }
                    Write-Diagnostic ("Rate: " + ($parts -join " ; "))
                }
            }

            # If status is 2xx, parse and return
            if ($statusCode -ne $null -and $statusCode -ge 200 -and $statusCode -lt 300) {
                $content = $webResp.Content
                if ($content -and $content.Trim() -ne '') {
                    try {
                        $resp = $content | ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        $resp = $content
                    }
                } else {
                    $resp = $null
                }
                return $resp
            }

            # Non-2xx response: log body preview and decide whether to wait/retry
            $body = $webResp.Content
            if ($body) {
                Write-Diagnostic "GitHub API returned HTTP $statusCode for $Url"
                Write-Diagnostic "Response body preview:"
                $preview = $body.Substring(0,[Math]::Min(800,$body.Length))
                $preview -split "`n" | ForEach-Object { Write-Host $_ }
                Write-Host ""
            } else {
                Write-Diagnostic "GitHub API returned HTTP $statusCode for $Url (no body)"
            }

            # Extract headers for retry logic
            $retryAfter = $null
            $rateReset = $null
            try {
                if ($webResp.Headers) {
                    if ($webResp.Headers['Retry-After']) { $retryAfter = [int]$webResp.Headers['Retry-After'] }
                    if ($webResp.Headers['X-RateLimit-Reset']) { $rateReset = [int]$webResp.Headers['X-RateLimit-Reset'] }
                    if ($webResp.Headers['X-RateLimit-Remaining']) {
                        $rem = $webResp.Headers['X-RateLimit-Remaining']
                        $lim = $webResp.Headers['X-RateLimit-Limit']
                        if ($rem -eq '0') {
                            # If remaining is zero, prefer waiting until reset
                            if ($rateReset) {
                                $nowEpoch = [int](Get-Date -UFormat %s)
                                $wait = $rateReset - $nowEpoch
                                if ($wait -gt 0) {
                                    Write-Diagnostic "Rate limit exhausted; waiting $wait seconds until reset (epoch $rateReset). Attempt $attempt of $maxAttempts."
                                    Start-Sleep -Seconds $wait
                                }
                            }
                        }
                    }
                }
            } catch {
                # ignore header extraction errors
            }

            # Honor Retry-After if present
            if ($retryAfter -ne $null -and $retryAfter -gt 0) {
                Write-Diagnostic "Server asked to retry after $retryAfter seconds. Attempt $attempt of $maxAttempts."
                Start-Sleep -Seconds $retryAfter
            } else {
                # Exponential backoff for other HTTP errors (if we will retry)
                if ($attempt -lt $maxAttempts) {
                    $delay = $baseDelaySeconds * [math]::Pow(2, $attempt - 1)
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

        # If we reach here, Invoke-WebRequest did not return a response object (network-level error)
        try {
            # Re-run to get exception details (this will throw)
            $null = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction Stop
        } catch [System.Net.WebException] {
            $we = $_.Exception
            # Try to extract headers from the WebException response if available and log them
            try {
                if ($we.Response -ne $null) {
                    $respHeaders = $we.Response.Headers
                    $retryAfter = if ($respHeaders['Retry-After']) { [int]$respHeaders['Retry-After'] } else { $null }
                    $rateReset = if ($respHeaders['X-RateLimit-Reset']) { [int]$respHeaders['X-RateLimit-Reset'] } else { $null }
                    $rem = if ($respHeaders['X-RateLimit-Remaining']) { $respHeaders['X-RateLimit-Remaining'] } else { $null }
                    $lim = if ($respHeaders['X-RateLimit-Limit']) { $respHeaders['X-RateLimit-Limit'] } else { $null }

                    if ($lim -or $rem -or $rateReset -or $retryAfter) {
                        $parts = @()
                        if ($rem -and $lim) { $parts += "remaining=$rem/$lim" }
                        elseif ($rem) { $parts += "remaining=$rem" }
                        elseif ($lim) { $parts += "limit=$lim" }
                        if ($rateReset) {
                            $nowEpoch = [int](Get-Date -UFormat %s)
                            $wait = [int]$rateReset - $nowEpoch
                            if ($wait -lt 0) { $wait = 0 }
                            $parts += "reset_epoch=$rateReset; in ${wait}s"
                        }
                        if ($retryAfter) { $parts += "retry_after=${retryAfter}s" }
                        Write-Diagnostic ("Rate (error): " + ($parts -join " ; "))
                    }

                    # If Retry-After present, honor it
                    if ($retryAfter -ne $null -and $retryAfter -gt 0) {
                        Write-Diagnostic "Rate limit or server asked to retry after $retryAfter seconds. Attempt $attempt of $maxAttempts."
                        Start-Sleep -Seconds $retryAfter
                    } elseif ($rateReset -ne $null) {
                        $nowEpoch = [int](Get-Date -UFormat %s)
                        $wait = $rateReset - $nowEpoch
                        if ($wait -gt 0) {
                            Write-Diagnostic "Rate limit reset at epoch $rateReset (in $wait seconds). Attempt $attempt of $maxAttempts."
                            Start-Sleep -Seconds $wait
                        }
                    }
                }
            } catch {
                # ignore header extraction errors
            }

            # Exponential backoff for network errors
            if ($attempt -lt $maxAttempts) {
                $delay = $baseDelaySeconds * [math]::Pow(2, $attempt - 1)
                Write-Diagnostic "Network error calling GitHub API: $($we.Message). Backing off $delay seconds. Attempt $attempt of $maxAttempts."
                Start-Sleep -Seconds $delay
                continue
            } else {
                throw
            }
        } catch {
            # Other exceptions
            if ($attempt -lt $maxAttempts) {
                $delay = $baseDelaySeconds * [math]::Pow(2, $attempt - 1)
                Write-Diagnostic "Error calling GitHub API: $($_.Exception.Message). Backing off $delay seconds. Attempt $attempt of $maxAttempts."
                Start-Sleep -Seconds $delay
                continue
            } else {
                throw
            }
        }
    }
}

# Normalize accounts list
$accountList = $Accounts -split '[, ]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($accountList.Count -eq 0) {
    Write-DiagnosticError "No valid accounts provided in -Accounts parameter."
    exit 2
}

# Collect repo entries
$allRepos = @()

foreach ($acct in $accountList) {
    Write-Host "Fetching repos for: $acct"

    $listUrl = "https://api.github.com/users/$acct/repos?per_page=100"
    try {
        $repos = Invoke-GitHubApi -Url $listUrl
    } catch {
        Write-DiagnosticWarning "Warning: Account '$acct' not found or inaccessible (HTTP error)."
        # End of iteration: print exactly one empty line then continue
        Write-Host ""
        continue
    }

    if ($SaveDebugFiles) {
        $listFile = Join-Path $debugDir ("list_{0}.json" -f $acct)
        try { $repos | ConvertTo-Json -Depth 10 | Out-File -FilePath $listFile -Encoding UTF8 } catch {}
    }

    foreach ($r in $repos) {
        if ($SkipDotPrefix -and $r.name.StartsWith('.')) { continue }
        if ($HideForks -and $r.fork) { continue }

        $owner = $r.owner.login
        $repoName = $r.name
        $detailUrl = "https://api.github.com/repos/$owner/$repoName"
        try {
            # Try to fetch full repo detail (may include parent/source for forks)
            $detail = Invoke-GitHubApi -Url $detailUrl
        } catch {
            # If detail fetch fails (common for some forks or rate-limited responses),
            # fall back to using the list-item data ($r) so we still include the repo.
            Write-DiagnosticWarning "Warning: Failed to fetch details for $owner/$repoName. Using list data and continuing."
            $detail = $r
        }

        if ($SaveDebugFiles) {
            $safeName = ($owner + '_' + $repoName) -replace '[\\/:*?""<>| ]','_'
            $detailFile = Join-Path $debugDir ("detail_{0}.json" -f $safeName)
            try { $detail | ConvertTo-Json -Depth 20 | Out-File -FilePath $detailFile -Encoding UTF8 } catch {}
        }

        # Safe extraction of optional properties
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

    # End of iteration: print exactly one empty line
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
