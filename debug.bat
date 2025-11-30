@echo off
REM diag_listgh.bat
REM Shows the latest run log, lists .Count usages in the PS1, and prints lines around the first Count error.

setlocal

echo.
echo === Locating latest run log in "%~dp0logs" ===
for /f "usebackq delims=" %%F in (`powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0logs' -Filter 'run_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }"`) do set "LATEST=%%F"

if not defined LATEST (
  echo No log files found in "%~dp0logs"
  echo.
) else (
  echo Latest log: %LATEST%
  echo.
  echo === First 80 lines of latest log ===
  powershell -NoProfile -Command "Get-Content -Path '%LATEST%' -TotalCount 80" 2>nul
  echo.
)

echo === Searching script for occurrences of '.Count' ===
if exist "%~dp0ListGitHubRepos.ps1" (
  powershell -NoProfile -Command "Select-String -Path '%~dp0ListGitHubRepos.ps1' -Pattern '\.Count' -AllMatches | ForEach-Object { '{0}:{1}' -f $_.LineNumber, $_.Line.Trim() }" 2>nul
) else (
  echo Script file not found: "%~dp0ListGitHubRepos.ps1"
)
echo.

echo === Showing context around first 'Count' error in the latest log ===
if defined LATEST (
  powershell -NoProfile -Command ^
    "$log = Get-Content -Path '%LATEST%'; $match = $log | Select-String -Pattern 'Property ''Count'' cannot be found' -SimpleMatch | Select-Object -First 1; if ($null -eq $match) { Write-Host 'No Count error line found in the latest log.' } else { $idx = $match.LineNumber; $start = [Math]::Max(1, $idx - 5); $end = [Math]::Min($log.Count, $idx + 10); $log[$start-1..($end-1)] | ForEach-Object { $_ } }" 2>nul
) else (
  echo No latest log to inspect.
)
echo.

echo === Show the exact line numbers in the script that reference '.Count' with 3 lines of context each ===
if exist "%~dp0ListGitHubRepos.ps1" (
  powershell -NoProfile -Command "Select-String -Path '%~dp0ListGitHubRepos.ps1' -Pattern '\.Count' -AllMatches | ForEach-Object { $ln = $_.LineNumber; Write-Host '--- Line' $ln '---'; Get-Content -Path '%~dp0ListGitHubRepos.ps1' -TotalCount ($ln+1) | Select-Object -Last 3 }" 2>nul
) else (
  echo Script file not found: "%~dp0ListGitHubRepos.ps1"
)
echo.

echo === End of diagnostics ===
endlocal
pause