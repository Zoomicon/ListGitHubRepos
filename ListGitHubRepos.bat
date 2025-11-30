@echo off
rem RunListGitHub_OpenOnSuccess.bat
rem Usage: RunListGitHub_OpenOnSuccess.bat [accounts]
rem Falls back to ListGitHubRepos_Accounts env var or prompts if needed.
setlocal

set "SCRIPT=ListGitHubRepos.ps1"
set "OUTPUT=GitHubRepos.html"

rem --- determine accounts ---
if "%~1"=="" (
  if defined ListGitHubRepos_Accounts (
    set "ACCOUNTS=%ListGitHubRepos_Accounts%"
  ) else (
    set /p "ACCOUNTS=Enter GitHub accounts (comma or space separated): "
  )
) else (
  set "ACCOUNTS=%~1"
)

if "%ACCOUNTS%"=="" (
  echo No accounts provided. Exiting.
  pause
  endlocal
  exit /b 1
)

echo Accounts = %ACCOUNTS%
if defined GITHUB_TOKEN (
  echo GITHUB_TOKEN is set (using authenticated requests)
) else (
  echo No GITHUB_TOKEN set (unauthenticated requests)
)
echo.

rem Optional: uncomment to set max attempts explicitly (default is 4 in the script)
:: set MAX_ATTEMPTS=4

rem Optional flags (uncomment to enable)
:: set HIDE_FORKS=1
:: set SKIP_DOT=1
:: set SAVE_DEBUG=1

rem Export GITHUB_TOKEN into the environment for the PowerShell process if provided
if defined GITHUB_TOKEN (
  set "GITHUB_TOKEN=%GITHUB_TOKEN%"
)

rem --- build extra args safely ---
set "EXTRA_ARGS="

if defined MAX_ATTEMPTS (
  set "EXTRA_ARGS=%EXTRA_ARGS% -MaxAttempts %MAX_ATTEMPTS%"
)

if defined HIDE_FORKS (
  set "EXTRA_ARGS=%EXTRA_ARGS% -HideForks"
)

if defined SKIP_DOT (
  set "EXTRA_ARGS=%EXTRA_ARGS% -SkipDotPrefix"
)

if defined SAVE_DEBUG (
  set "EXTRA_ARGS=%EXTRA_ARGS% -SaveDebugFiles"
)

rem --- run the PowerShell script from this batch's folder ---
pushd "%~dp0"

rem Call PowerShell with -File and pass -Accounts as a separate, quoted argument.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0%SCRIPT%" -Accounts "%ACCOUNTS%" %EXTRA_ARGS%
set "PS_EXIT=%ERRORLEVEL%"

rem --- open output only if PowerShell succeeded and file exists ---
if "%PS_EXIT%"=="0" (
  if exist "%~dp0%OUTPUT%" (
    echo PowerShell completed successfully. Opening %OUTPUT%...
    start "" "%~dp0%OUTPUT%"
  ) else (
    echo PowerShell completed with exit code 0 but %OUTPUT% was not found.
  )
) else (
  echo PowerShell failed with exit code %PS_EXIT%. Not opening %OUTPUT%.
)

popd
endlocal
echo.
pause
