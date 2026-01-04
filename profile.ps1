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
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.DirectoryManagement'
)
$allModulesPresent = $true

Write-Host "Profile.ps1: Cold start initialization..." -ForegroundColor Cyan
Write-Host "Profile.ps1: PSModulePath = $env:PSModulePath" -ForegroundColor Cyan
Write-Host "Determining home directory"
$targetFolderName = "EventGridTrigger1"
$targetPath = Get-ChildItem -Path $env:HOME -Recurse -Directory -Filter $targetFolderName -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host "Profile.ps1: Home directory = $($targetPath.FullName)" -ForegroundColor Cyan
if (-not $targetPath)
{
    Write-Warning "Profile.ps1: Could not find target folder '$targetFolderName' under HOME directory."
}
else
{
    $targetModulePath = Join-Path -Path $targetPath.FullName -ChildPath "Modules"
    if (Test-Path -Path $targetModulePath)
    {
        #get the count of folders in the Modules path
        $moduleFolderCount = (Get-ChildItem -Path $targetModulePath -Directory).Count
        Write-Host "Profile.ps1: Found Modules folder at $targetModulePath with $moduleFolderCount module folders." -ForegroundColor Green
        foreach ($module in $requiredModules)
        {
            Write-Host "Profile.ps1: Ensuring module '$module' is available..." -ForegroundColor Cyan
            if (Test-Path -Path (Join-Path -Path $targetModulePath -ChildPath $module) -ErrorAction SilentlyContinue -eq $false                                                 )
            {
                Write-Host "Profile.ps1: Module '$module' is available." -ForegroundColor Green
            }
            else
            {
                Write-Warning "Profile.ps1: Module '$module' is NOT available in Modules folder."
                $allModulesPresent = $false
            }
        }
        if ($allModulesPresent)
        {
            Write-Host "Profile.ps1: All required modules are present." -ForegroundColor Green
            $env:PSModulePath = "$targetModulePath;$env:PSModulePath"
        }
        else
        {
            Write-Warning "Profile.ps1: One or more required modules are missing. Please check the Modules folder."
        }
    }
    else
    {
        Write-Warning "Profile.ps1: Modules folder not found at expected path: $targetModulePath"
    }
    Write-Host "Profile.ps1: Updated PSModulePath = $env:PSModulePath" -ForegroundColor Cyan
}
Write-Host "Profile.ps1: Cold start initialization complete." -ForegroundColor Green
