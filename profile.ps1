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
# You do NOT need to manually import modules here - they will be auto-loaded when referenced.
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.DirectoryManagement'
)
$foundModules = @()
$missingModules = @()
$pathSeperater = if ($env:OS -eq "Windows_NT")
{
    ";"
}
else
{
    ":"
}
Write-Host "Profile.ps1: Cold start initialization..." -ForegroundColor Cyan
Write-Host "Profile.ps1: Path Seperater is $pathSeperater" -ForegroundColor Cyan
$modulesFolders = ($env:PSModulePath.Split($pathSeperater) | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
Write-Host "Profile.ps1: Found $($modulesFolders.Count) module folders in PSModulePath:" -ForegroundColor Cyan
foreach ($folder in $modulesFolders)
{
    Write-Host "Profile.ps1: - Looking for required modules in folder: $folder" -ForegroundColor Cyan
    # Reset for each folder
    $foundModules = @()
    $missingModules = @()
    #Check if it contains our required modules by looking for the folder names.
    $modulesList = (Get-ChildItem -Path $folder -Directory -ErrorAction SilentlyContinue).Name
    # Check if ALL required modules exist as folders in this path
    foreach ($module in $requiredModules)
    {
        if ($modulesList -notcontains $module)
        {
            Write-Verbose "Profile.ps1:   Missing module: $module"
            $missingModules += $module
        }
        else
        {
            Write-Host "Profile.ps1:   Found module: $module"
            $foundModules += $module
        }
    }

    # Check if we found all required modules in this folder
    $allModulesPresent = ($foundModules.Count -eq $requiredModules.Count) -and
    ($missingModules.Count -eq 0)

    if ($allModulesPresent)
    {
        Write-Host "Profile.ps1: All required modules found in folder: $folder" -ForegroundColor Green
        break
    }
    else
    {
        Write-Host "Profile.ps1: $(if ($missingModules.Count -eq $requiredModules.Count -and $foundModules.count -eq 0) { 'No required modules found.' } else { 'Missing modules: ' + ($missingModules -join ', ') })" -ForegroundColor Yellow
    }
}

Write-Host "Profile.ps1: Cold start initialization complete." -ForegroundColor Green


