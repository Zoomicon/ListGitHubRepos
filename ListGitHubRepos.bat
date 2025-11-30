@echo off
REM ===== Fixed ListGitHubRepos_Run.bat =====
REM Robust runner: no nested parenthesized blocks, all literal parentheses escaped.

setlocal

REM --- Config (edit if desired) ---
set "SCRIPT_PATH=%~dp0ListGitHubRepos.ps1"
set "GITHUB_TOKEN="        REM optional: paste token here to avoid 403s
set "MAX_ATTEMPTS=4"
set "EXCLUDE_NAMES=.github"

REM --- Parse args ---
set "NOLOG=0"
set "QUIET=0"
set "ACCS="
:arg_loop
if "%~1"=="" goto args_done
if "%~1"=="-nolog" set "NOLOG=1" & shift & goto arg_loop
if "%~1"=="-quiet" set "QUIET=1" & shift & goto arg_loop
if defined ACCS ( set "ACCS=%ACCS% %~1" ) else ( set "ACCS=%~1" )
shift
goto arg_loop
:args_done

REM --- Prompt if no accounts provided ---
if not defined ACCS (
  set /p "ACCS=Enter GitHub accounts (space separated): "
)

REM --- Sanitize input ---
set "ACCS=%ACCS:"=%"
set "ACCS=%ACCS:,= %"
:trim_spaces
set "OLDACCS=%ACCS%"
set "ACCS=%ACCS:  = %"
if not "%ACCS%"=="%OLDACCS%" goto trim_spaces

REM --- Timestamps and paths (safe calls before conditionals) ---
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"`) do set "TS=%%T"
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss' "`) do set "RUN_TS=%%T"

set "LOGDIR=%~dp0logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
set "LOGFILE=%LOGDIR%\run_%TS%.log"
set "DEBUG_DIR=%~dp0repo-debug"

if not "%GITHUB_TOKEN%"=="" set "GITHUB_TOKEN=%GITHUB_TOKEN%"

REM --- Header (single-line ifs only; literal parentheses escaped where present) ---
if "%QUIET%"=="0" echo =====================================================
if "%QUIET%"=="0" echo ListGitHubRepos runner
if "%QUIET%"=="0" echo Timestamp: %RUN_TS%
if "%QUIET%"=="0" echo Accounts: %ACCS%
if "%QUIET%"=="0" if "%NOLOG%"=="1" (echo Logging: OFF) else (echo Logging: ON - log file: "%LOGFILE%")
if "%QUIET%"=="0" echo Verbose messages: ON
if "%QUIET%"=="0" echo =====================================================
if "%QUIET%"=="0" echo.

REM --- Run path selection (explicit GOTOs; no nested blocks) ---
if "%NOLOG%"=="1" goto RUN_NOLOG
goto RUN_LOG

:RUN_NOLOG
if "%QUIET%"=="0" echo Running (no log) for accounts: %ACCS%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -Accounts "%ACCS%" -SaveDebugFiles -MaxAttempts %MAX_ATTEMPTS% -ExcludeNames "%EXCLUDE_NAMES%"
call set "EXITCODE=%%ERRORLEVEL%%"
goto AFTER_RUN

:RUN_LOG
if "%QUIET%"=="0" echo Running (logging) for accounts: %ACCS% and writing to %LOGFILE%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -Accounts "%ACCS%" -SaveDebugFiles -MaxAttempts %MAX_ATTEMPTS% -ExcludeNames "%EXCLUDE_NAMES%" > "%LOGFILE%" 2>&1
call set "EXITCODE=%%ERRORLEVEL%%"
goto AFTER_RUN

:AFTER_RUN
REM --- Summary (single-line ifs only; avoid nested inline ifs with literal parentheses) ---
if "%QUIET%"=="0" echo.
if "%QUIET%"=="0" echo ==== RUN SUMMARY ====
if "%QUIET%"=="0" if "%NOLOG%"=="1" goto LOG_DISABLED
if "%QUIET%"=="0" echo Log file: %LOGFILE%
goto LOG_AFTER

:LOG_DISABLED
if "%QUIET%"=="0" echo Log file: ^(disabled^)
:LOG_AFTER

if "%QUIET%"=="0" if exist "%~dp0GitHubRepos.html" (
  echo Generated HTML: %~dp0GitHubRepos.html
  echo Opening HTML...
  start "" "%~dp0GitHubRepos.html"
) else (
  if "%QUIET%"=="0" echo Generated HTML: (not found)
)

if "%QUIET%"=="0" if exist "%~dp0repo-debug" echo Repo debug files: %~dp0repo-debug
if "%QUIET%"=="0" echo Exit code: %EXITCODE%
if "%QUIET%"=="0" echo ====================
if "%QUIET%"=="0" echo.

REM --- Show preview outside any multi-line block ---
if "%NOLOG%"=="0" call :ShowLogPreview

endlocal
exit /b %EXITCODE%

:ShowLogPreview
  if exist "%LOGFILE%" (
    powershell -NoProfile -Command "if (Test-Path '%LOGFILE%') { Get-Content -Path '%LOGFILE%' -TotalCount 30 }" 2>nul
  ) else (
    echo (no log file found)
  )
  goto :eof
