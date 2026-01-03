# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution

# IMPORTANT: For Flex Consumption plan, the Azure Functions PowerShell worker automatically
# adds the Modules/ folder to $env:PSModulePath. This enables module autoloading.
# You do NOT need to manually import modules here - they will be auto-loaded when referenced.

Write-Host "Profile.ps1: Cold start initialization..." -ForegroundColor Cyan
Write-Host "Profile.ps1: PSModulePath = $env:PSModulePath" -ForegroundColor Cyan

# Verify that the Modules folder is in PSModulePath
$modulesInPath = $env:PSModulePath -split ';' | Where-Object { $_ -like '*Modules*' }
if ($modulesInPath)
{
    Write-Host "Profile.ps1: Modules folder found in PSModulePath" -ForegroundColor Green
    foreach ($path in $modulesInPath)
    {
        Write-Host "  - $path" -ForegroundColor Cyan
    }
}
else
{
    Write-Warning "Profile.ps1: No Modules folder found in PSModulePath. This may indicate a deployment issue."
}

Write-Host "Profile.ps1: Cold start initialization complete." -ForegroundColor Green
