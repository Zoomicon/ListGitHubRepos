# Diagnostic: show list-item and detail JSON and decisive fields for Birbilis/GridSearchDemo
$headers = @{ 'User-Agent' = 'PS' }
# If you have a token, uncomment and set it:
# $headers['Authorization'] = "token YOUR_GITHUB_TOKEN"

# 1) list endpoint (all repos for user)
$list = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/users/Birbilis/repos?per_page=200"
$list | Where-Object { $_.name -ieq 'GridSearchDemo' } | Select-Object full_name, name, @{n='list_fork';e={[bool]$_.fork}}, html_url | Format-List

# Save the raw list-item JSON to file (so we can inspect)
$list | Where-Object { $_.name -ieq 'GridSearchDemo' } | ConvertTo-Json -Depth 10 | Out-File -FilePath .\list_Birbilis_GridSearchDemo.json -Encoding UTF8

# 2) detail endpoint (authoritative)
$detail = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Birbilis/GridSearchDemo"
$detail | Select-Object full_name, @{n='detail_fork';e={[bool]$_.fork}}, @{n='hasParent';e={($_.parent -ne $null)}}, @{n='hasSource';e={($_.source -ne $null)}}, html_url | Format-List

# Save the raw detail JSON to file
$detail | ConvertTo-Json -Depth 10 | Out-File -FilePath .\detail_Birbilis_GridSearchDemo.json -Encoding UTF8

# Print file paths so you can open them
Write-Host "Saved: .\list_Birbilis_GridSearchDemo.json"
Write-Host "Saved: .\detail_Birbilis_GridSearchDemo.json"