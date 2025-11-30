@echo off
REM RunListGitHub_Log.bat
setlocal

set "SCRIPT=%~dp0ListGitHubRepos.ps1"

REM --- Configuration (edit these) ---
set "GITHUB_TOKEN="        REM <-- put your token here (keep file private)
set "HIDE_FORKS=0"
set "SKIP_DOT=0"
set "SAVE_DEBUG=1"        REM enable saving debug responses
set "MAX_ATTEMPTS=4"
set "EXCLUDE_NAMES=.github"
set "SHOW_STARS=0"
set "SHOW_FORKS=0"
set "STARS_LABEL=Stars:"
set "FORKS_LABEL=Forks:"
set "ITALIC_NAMES=.github"

REM timestamp for log filename (avoid single quotes inside the command)
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"`) do set "TS=%%T"

set "LOGDIR=%~dp0logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

set "LOGFILE=%LOGDIR%\run_%TS%.log"

REM Prompt for accounts (quoted form preserves ":" and trailing space)
if "%~1"=="" (
    set /p "ACCOUNTS=Enter GitHub accounts (comma or space separated): "
) else (
    set "ACCOUNTS=%*"
)

REM Export token and debug dir as environment variables for PowerShell
if not "%GITHUB_TOKEN%"=="" set "GITHUB_TOKEN=%GITHUB_TOKEN%"
set "DEBUG_DIR=%~dp0repo-debug"

REM Build PowerShell argument string (do NOT pass -DebugDir)
set "PSARGS=-NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Accounts "%ACCOUNTS%""
if "%HIDE_FORKS%"=="1" call set "PSARGS=%%PSARGS%% -HideForks"
if "%SKIP_DOT%"=="1" call set "PSARGS=%%PSARGS%% -SkipDotPrefix"
if "%SAVE_DEBUG%"=="1" call set "PSARGS=%%PSARGS%% -SaveDebugFiles"
if not "%MAX_ATTEMPTS%"=="" call set "PSARGS=%%PSARGS%% -MaxAttempts %MAX_ATTEMPTS%"
if not "%EXCLUDE_NAMES%"=="" call set "PSARGS=%%PSARGS%% -ExcludeNames "%EXCLUDE_NAMES%""
if "%SHOW_STARS%"=="1" call set "PSARGS=%%PSARGS%% -ShowStars"
if "%SHOW_FORKS%"=="1" call set "PSARGS=%%PSARGS%% -ShowForks"
if not "%STARS_LABEL%"=="" call set "PSARGS=%%PSARGS%% -StarsLabel "%STARS_LABEL%""
if not "%FORKS_LABEL%"=="" call set "PSARGS=%%PSARGS%% -ForksLabel "%FORKS_LABEL%""
if not "%ITALIC_NAMES%"=="" call set "PSARGS=%%PSARGS%% -ItalicNames "%ITALIC_NAMES%""

echo Running PowerShell and saving output to:
echo   %LOGFILE%
echo.
echo Command:
echo   powershell.exe %PSARGS%
echo.

REM Run PowerShell and capture stdout+stderr into the log
powershell.exe %PSARGS% > "%LOGFILE%" 2>&1
set "EXITCODE=%ERRORLEVEL%"

REM Append summary safely (escape parentheses or avoid them)
(
  echo.
  echo ==== EXIT CODE: %EXITCODE% ====
  echo Generated HTML at: %~dp0GitHubRepos.html
  echo.
  echo ==== repo-debug directory listing ====
) >> "%LOGFILE%"

REM Use path without a trailing backslash in the IF test to avoid parser issues
if exist "%~dp0repo-debug" (
    dir /b "%~dp0repo-debug" >> "%LOGFILE%" 2>&1
) else (
    echo (no repo-debug directory found) >> "%LOGFILE%"
)

echo.
echo Log saved to: %LOGFILE%
if exist "%~dp0repo-debug" echo Repo debug files saved in: %~dp0repo-debug
echo.

endlocal
exit /b %EXITCODE%
