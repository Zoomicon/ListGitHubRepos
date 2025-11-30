@echo off
REM ListGitHubRepos.bat
REM Constants are defined here; edit them instead of using environment variables.
setlocal

set "SCRIPT=%~dp0ListGitHubRepos.ps1"

REM --- Configuration constants (edit these) ---
set "GITHUB_TOKEN="        REM <-- put your token here, keep this file private
set "HIDE_FORKS=0"
set "SKIP_DOT=0"
set "SAVE_DEBUG=1"         REM enable saving debug responses
set "MAX_ATTEMPTS=4"
set "EXCLUDE_NAMES=.github"
set "SHOW_STARS=0"
set "SHOW_FORKS=0"
set "STARS_LABEL=Stars:"
set "FORKS_LABEL=Forks:"
set "ITALIC_NAMES=.github"

if "%~1"=="/?" goto help
if "%~1"=="-h" goto help

goto collect_args

:collect_args
REM Prompt for accounts (quoted form preserves ":" and trailing space)
if "%~1"=="" (
    set /p "ACCOUNTS=Enter GitHub accounts (comma or space separated): "
) else (
    set "ACCOUNTS=%*"
)

REM Export token and debug dir as environment variables for PowerShell
if not "%GITHUB_TOKEN%"=="" set "GITHUB_TOKEN=%GITHUB_TOKEN%"
set "DEBUG_DIR=%~dp0repo-debug"

REM Build PowerShell argument string (use CALL SET to avoid parser issues)
set "PSARGS=-NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Accounts "%ACCOUNTS%""

if "%HIDE_FORKS%"=="1" call set "PSARGS=%%PSARGS%% -HideForks"
if "%SKIP_DOT%"=="1" call set "PSARGS=%%PSARGS%% -SkipDotPrefix"
if "%SAVE_DEBUG%"=="1" call set "PSARGS=%%PSARGS%% -SaveDebugFiles"

if not "%MAX_ATTEMPTS%"=="" call set "PSARGS=%%PSARGS%% -MaxAttempts %MAX_ATTEMPTS%"

if not "%EXCLUDE_NAMES%"=="" (
    call set "PSARGS=%%PSARGS%% -ExcludeNames "%EXCLUDE_NAMES%""
)

if "%SHOW_STARS%"=="1" call set "PSARGS=%%PSARGS%% -ShowStars"
if "%SHOW_FORKS%"=="1" call set "PSARGS=%%PSARGS%% -ShowForks"

if not "%STARS_LABEL%"=="" (
    call set "PSARGS=%%PSARGS%% -StarsLabel "%STARS_LABEL%""
)

if not "%FORKS_LABEL%"=="" (
    call set "PSARGS=%%PSARGS%% -ForksLabel "%FORKS_LABEL%""
)

if not "%ITALIC_NAMES%"=="" (
    call set "PSARGS=%%PSARGS%% -ItalicNames "%ITALIC_NAMES%""
)

echo.
echo Running PowerShell:
echo powershell.exe %PSARGS%
echo.

powershell.exe %PSARGS%
set "EXITCODE=%ERRORLEVEL%"

if "%EXITCODE%"=="0" (
    if exist "%~dp0GitHubRepos.html" (
        start "" "%~dp0GitHubRepos.html"
    )
) else (
    echo PowerShell failed with exit code %EXITCODE%.
)

endlocal
exit /b %EXITCODE%

:help
echo Usage: ListGitHubRepos.bat [accounts]
echo.
echo Edit the constants at the top of this file to change behavior; do not rely on environment variables.
exit /b 0
