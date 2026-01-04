<#
.SYNOPSIS
    Downloads and installs required Microsoft Graph PowerShell modules.

.DESCRIPTION
    This script locates or creates a modules folder in the directory hierarchy and installs
    the required Microsoft Graph PowerShell modules needed for the function app. It supports
    clean installation by removing existing modules before reinstalling them.

.PARAMETER cleanInstall
    When specified, removes existing modules before installing them again.
    If not specified, skips modules that are already installed.

.EXAMPLE
    .\get-modules.ps1
    Installs required modules, skipping any that already exist.

.EXAMPLE
    .\get-modules.ps1 -cleanInstall
    Removes and reinstalls all required modules.

.NOTES
    Required Modules:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Groups
    - Microsoft.Graph.Users
    - Microsoft.Graph.Identity.DirectoryManagement

    Exit Codes:
    - 0: All modules installed successfully
    - 1: Failed to find modules folder or failed to install one or more modules
#>
[CmdletBinding()]
param (
    [switch]$cleanInstall
)

function Find-FolderPath()
{
    <#
        .SYNOPSIS
            Searches upward from the given path for a folder with the specified name.
        .PARAMETER Path
            The starting path to begin searching from.
        .PARAMETER FolderName
            The name of the folder to search for.
        .OUTPUTS
            Returns the full path to the folder if found, otherwise $null.
        #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$FolderName
    )
    $functionName = $MyInvocation.MyCommand.Name
    #write verbose log of received parameters
    Write-Verbose "[$functionName] Find-FolderPath called with Path: $Path, FolderName: $FolderName"
    try
    {
        $currentPath = (Resolve-Path -Path $Path).Path
        Write-Verbose "[$functionName] Current path resolved to: $currentPath"

        # 1. Search children (recursively) of the starting path
        Write-Verbose "[$functionName] Searching children of $currentPath for folder named $FolderName"
        $childMatch = Get-ChildItem -Path $currentPath -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $FolderName } | Select-Object -First 1
        Write-Verbose "[$functionName] Checking child match: $($childMatch.FullName)"
        if ($childMatch)
        {
            Write-Verbose "[$functionName] Found folder in children: $($childMatch.FullName)"
            return $childMatch.FullName
        }
        # Also check if the starting path itself matches
        if ((Split-Path -Path $currentPath -Leaf) -ieq $FolderName)
        {
            Write-Verbose "[$functionName] Starting path itself matches: $currentPath"
            return $currentPath
        }

        # 2. Search up the parent chain, at each level search its children for the folder
        while ($currentPath)
        {
            $parent = Split-Path -Path $currentPath -Parent
            if ($parent -eq $currentPath -or [string]::IsNullOrEmpty($parent))
            {
                break
            } # Reached root
            Write-Verbose "[$functionName] Searching children of parent: $parent for folder named $FolderName"
            $siblingMatch = Get-ChildItem -Path $parent -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $FolderName } | Select-Object -First 1
            if ($siblingMatch)
            {
                Write-Verbose "[$functionName] Found folder in parent: $($siblingMatch.FullName)"
                return $siblingMatch.FullName
            }
            # Also check if the parent itself matches
            if ((Split-Path -Path $parent -Leaf) -ieq $FolderName)
            {
                Write-Verbose "[$functionName] Parent itself matches: $parent"
                return $parent
            }
            $currentPath = $parent
        }
        Write-Verbose "[$functionName] No folder found with name $FolderName in children or parent hierarchy."
        return $null
    }
    catch
    {
        Write-Error "[$functionName] Error occurred while searching for folder: $_"
        return $null
    }
}

#region variables
$modulesFolder = find-folderPath -Path $PSScriptRoot -FolderName 'modules'
$installedModules = @()
$failedModules = @()
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.DirectoryManagement'
)
#endregion variables

if (-not $modulesFolder)
{
    Write-Error "Could not find 'modules' folder in the directory hierarchy."
    exit 1
}

Write-Host "Processing $($requiredModules.Count) required modules..."
foreach ($requiredModule in $requiredModules)
{
    $modulePath = Join-Path -Path $modulesFolder -ChildPath $requiredModule
    Write-Host "Checking for module: $requiredModule at path: $modulePath"
    if (Test-Path -Path $modulePath)
    {
        if ($cleanInstall)
        {
            Write-Host "Removing existing module: $requiredModule"
            Remove-Item -Path $modulePath -Recurse -Force
        }
        else
        {
            Write-Host "Module already exists: $requiredModule"
            continue
        }
    }

    Write-Host "Saving module: $requiredModule"
    try
    {
        Save-Module -Name $requiredModule -Path $modulesFolder -Force -ErrorAction Stop
        Write-Host "Successfully saved module: $requiredModule"
        $installedModules += $requiredModule
    }
    catch
    {
        Write-Error "Failed to install module: $requiredModule. Error: $_"
        $failedModules += $requiredModule
    }
}

Write-Host "Module installation summary:"
Write-Host "Successfully installed modules: $($installedModules -join ', ')"
if ($failedModules.Count -gt 0)
{
    Write-Host "Failed to install modules: $($failedModules -join ', ')"
    exit 1
}
else
{
    Write-Host "All required modules installed successfully."
    exit 0
}
