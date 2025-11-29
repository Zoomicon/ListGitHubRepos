@echo off
rem Set accounts to test (comma or space separated)
set ACCOUNTS=Zoomicon, Birbilis

rem Optional: set a GitHub token to avoid rate limits (uncomment and paste your token)
rem set GITHUB_TOKEN=ghp_xxxYOURTOKENxxx

rem Path to the PowerShell script (adjust if your script has a different name)
set SCRIPT=ListGitHubRepos.ps1

echo ACCOUNTS value: %ACCOUNTS%
echo Running PowerShell script with -HideForks and -SaveDebugFiles...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Accounts "%ACCOUNTS%" -HideForks -SaveDebugFiles

echo.
echo Done. If -SaveDebugFiles was used, check the repo-debug folder next to the script.
pause