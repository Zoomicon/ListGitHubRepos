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
.EXAMPLE
  .\ListGitHubRepos.ps1 -Accounts "octocat, microsoft" -HideForks -SaveDebugFiles
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Accounts,

    [switch]$HideForks,
    [switch]$SkipDotPrefix,
    [switch]$SaveDebugFiles
)

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
    try {
        $resp = Invoke-RestMethod -Uri $Url -Headers $headers -ErrorAction Stop
        return $resp
    } catch [System.Net.WebException] {
        $we = $_.Exception
        if ($we.Response -ne $null) {
            try {
                $stream = $we.Response.GetResponseStream()
                $sr = New-Object System.IO.StreamReader($stream)
                $body = $sr.ReadToEnd()
                Write-Diagnostic "GitHub API returned non-200 response for $Url"
                Write-Diagnostic "Response body preview:"
                # Print a preview of the body, each line followed by a newline
                $preview = $body.Substring(0,[Math]::Min(800,$body.Length))
                $preview -split "`n" | ForEach-Object { Write-Host $_ }
                Write-Host ""
            } catch {
                Write-Diagnostic "Failed to read error response body."
            }
        }
        throw
    } catch {
        throw
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
            $detail = Invoke-GitHubApi -Url $detailUrl
        } catch {
            Write-DiagnosticWarning "Warning: Failed to fetch details for $owner/$repoName. Skipping."
            continue
        }

        if ($SaveDebugFiles) {
            $safeName = ($owner + '_' + $repoName) -replace '[\\/:*?""<>| ]','_'
            $detailFile = Join-Path $debugDir ("detail_{0}.json" -f $safeName)
            try { $detail | ConvertTo-Json -Depth 20 | Out-File -FilePath $detailFile -Encoding UTF8 } catch {}
        }

        $allRepos += [PSCustomObject]@{
            Account      = $acct
            Owner        = $owner
            Name         = $repoName
            FullName     = $detail.full_name
            HtmlUrl      = $detail.html_url
            Description  = $detail.description
            Fork         = [bool]$detail.fork
            License      = $detail.license
            Parent       = $detail.parent
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
