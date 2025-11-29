@echo off
rem CheckGitHubRateReset.bat
rem Shows raw HTTP status and X-RateLimit-Reset if present

echo Querying https://api.github.com/rate_limit ...
curl -i -H "User-Agent: curl" "https://api.github.com/rate_limit"
echo.
echo If you see HTTP 403 or X-RateLimit-Remaining: 0 set a GITHUB_TOKEN and re-run.
pause