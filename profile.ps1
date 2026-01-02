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

# NOTE: Microsoft Graph PowerShell SDK uses Connect-MgGraph with -Identity
# which is called in the function code when needed.
# Azure Functions with managed identity automatically handles authentication.

# You can also define functions or aliases that can be referenced in any of your PowerShell functions.
# Pre-load the required assembly from bin directory
try
{
    $assemblyPath = Join-Path $PSScriptRoot "bin\Microsoft.Management.Infrastructure.dll"
    if (Test-Path $assemblyPath)
    {
        Add-Type -Path $assemblyPath -ErrorAction SilentlyContinue
        Write-Host "Loaded Microsoft.Management.Infrastructure from: $assemblyPath"
    }
    else
    {
        Write-Warning "Microsoft.Management.Infrastructure.dll not found at: $assemblyPath"
    }
}
catch
{
    Write-Warning "Could not pre-load Microsoft.Management.Infrastructure: $_"
}

# Manually import required Microsoft Graph modules
# This provides control over module loading order and timing
$modulesPath = Join-Path $PSScriptRoot "modules"
$requiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Groups'
    'Microsoft.Graph.Identity.DirectoryManagement'
)

foreach ($moduleName in $requiredModules)
{
    try
    {
        $modulePath = Join-Path $modulesPath $moduleName
        if (Test-Path $modulePath)
        {
            Import-Module $modulePath -Force -ErrorAction Stop
            Write-Host "Loaded module: $moduleName"
        }
        else
        {
            Write-Warning "Module not found: $moduleName at $modulePath"
        }
    }
    catch
    {
        Write-Warning "Failed to load module $moduleName : $_"
    }
}

