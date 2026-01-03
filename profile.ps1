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

# Pre-load required Microsoft Graph modules during cold start
# This ensures modules are available for all function invocations
# CRITICAL: Flex Consumption plan requires modules in app content (not managed dependencies)

$modulesPath = Join-Path $PSScriptRoot "modules"
if (-not (Test-Path $modulesPath))
{
    Write-Error "Modules folder not found at: $modulesPath"
}
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Identity.DirectoryManagement'
)
Write-Host "Profile.ps1: Starting module pre-load during cold start..." -ForegroundColor Cyan
foreach ($moduleName in $requiredModules)
{
    try
    {
        $modulePath = Join-Path $modulesPath $moduleName
        if (Test-Path $modulePath)
        {
            Write-Host "Profile.ps1: Importing $moduleName from $modulePath..." -ForegroundColor Cyan
            Import-Module -Name $modulePath -Force -ErrorAction Stop
            Write-Host "Profile.ps1: Successfully loaded module: $moduleName" -ForegroundColor Green
        }
        else
        {
            Write-Error "Profile.ps1: Module path not found: $modulePath"
        }
    }
    catch
    {
        Write-Error "Profile.ps1: Failed to import $moduleName : $_"
    }
}

Write-Host "Profile.ps1: Module pre-load complete." -ForegroundColor Green
