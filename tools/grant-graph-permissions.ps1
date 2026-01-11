#requires -Version 7
<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to the Function App's user-assigned managed identity.

.DESCRIPTION
    This script assigns the required Microsoft Graph application permissions to the user-assigned
    managed identity used by the Function App. This allows the RenewSubscription function to
    automatically renew Graph API subscriptions using the managed identity.

.PARAMETER ManagedIdentityName
    The name of the user-assigned managed identity. Default: groupchangefunction-identities-9bef22

.PARAMETER PrincipalId
    The principal (object) ID of the managed identity. Default: e4ad71a2-53c3-467f-a553-bc7eebf711b5

.EXAMPLE
    .\grant-graph-permissions.ps1
    Grants permissions to the default managed identity

.NOTES
    Requires:
    - Az.Accounts module
    - Az.Resources module
    - Global Administrator or Privileged Role Administrator role in Entra ID
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManagedIdentityName = "groupchangefunction-identities-9bef22",
    [Parameter()]
    [string]$PrincipalId = "e4ad71a2-53c3-467f-a553-bc7eebf711b5"
)

$ErrorActionPreference = "Stop"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Grant Microsoft Graph Permissions to Managed Identity" -ForegroundColor Cyan
Write-Host "================================================`n" -ForegroundColor Cyan

Write-Host "Managed Identity: $ManagedIdentityName" -ForegroundColor Yellow
Write-Host "Principal ID: $PrincipalId`n" -ForegroundColor Yellow

# Check if user is logged in to Azure
try
{
    $context = Get-AzContext -ErrorAction Stop
    if ($null -eq $context)
    {
        Write-Host "Not logged in to Azure. Connecting..." -ForegroundColor Yellow
        Connect-AzAccount
    }
    else
    {
        Write-Host "Already connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
    }
}
catch
{
    Write-Host "Not logged in to Azure. Connecting..." -ForegroundColor Yellow
    try
    {
        Connect-AzAccount
    }
    catch
    {
        Write-Host "Failed to connect to Azure: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-Host "`nStep 1: Getting Microsoft Graph Service Principal..." -ForegroundColor Cyan

# Microsoft Graph Application ID (this is constant)
$graphAppId = "00000003-0000-0000-c000-000000000000"

try
{
    # Get the Microsoft Graph service principal
    $graphSP = Get-AzADServicePrincipal -ApplicationId $graphAppId

    if ($null -eq $graphSP)
    {
        Write-Host "Could not find Microsoft Graph service principal" -ForegroundColor Red
        exit 1
    }

    Write-Host "Found Microsoft Graph service principal" -ForegroundColor Green
    Write-Host "   Object ID: $($graphSP.Id)" -ForegroundColor Gray
}
catch
{
    Write-Host "Error getting Microsoft Graph service principal: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "`nStep 2: Getting required permissions..." -ForegroundColor Cyan

# Define required permissions
$requiredPermissions = @(
    @{
        Name        = "Device.ReadWrite.All"
        Description = "Read and write devices"
    }
    @{
        Name        = "Directory.Read.All"
        Description = "Read all subscriptions"
    },
    @{
        Name        = "Directory.ReadWrite.All"
        Description = "Read and write all subscriptions"
    },
    @{
        Name        = "Group.Read.All"
        Description = "Read all groups (for subscription resource)"
    }
)
$permissionsToGrant = @()
foreach ($permission in $requiredPermissions)
{
    $role = $graphSP.AppRole | Where-Object { $_.Value -eq $permission.Name }
    if ($null -eq $role)
    {
        Write-Host "Warning: Could not find permission '$($permission.Name)'" -ForegroundColor Yellow
    }
    else
    {
        Write-Host "Found permission: $($permission.Name)" -ForegroundColor Green
        Write-Host "   Description: $($permission.Description)" -ForegroundColor Gray
        Write-Host "   Role ID: $($role.Id)" -ForegroundColor Gray
        $permissionsToGrant += @{
            Name        = $permission.Name
            RoleId      = $role.Id
            Description = $permission.Description
        }
    }
}

if ($permissionsToGrant.Count -eq 0)
{
    Write-Host "`nNo valid permissions found to grant" -ForegroundColor Red
    exit 1
}

Write-Host "`nStep 3: Checking existing role assignments..." -ForegroundColor Cyan
try
{
    # Get existing role assignments for this managed identity
    $existingAssignments = Get-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $PrincipalId |
        Where-Object { $_.ResourceId -eq $graphSP.Id }
    $existingRoleIds = $existingAssignments | ForEach-Object { $_.AppRoleId }
    Write-Host "Found $($existingAssignments.Count) existing assignment(s) to Microsoft Graph" -ForegroundColor Gray
}
catch
{
    Write-Host "Could not check existing assignments: $($_.Exception.Message)" -ForegroundColor Yellow
    $existingRoleIds = @()
}

Write-Host "`nStep 4: Granting permissions..." -ForegroundColor Cyan
$grantedCount = 0
$skippedCount = 0
$failedCount = 0
foreach ($permission in $permissionsToGrant)
{
    Write-Host "`nProcessing: $($permission.Name)..." -ForegroundColor Yellow
    # Check if already assigned
    if ($existingRoleIds -contains $permission.RoleId)
    {
        Write-Host "Already assigned - skipping" -ForegroundColor Gray
        $skippedCount++
        continue
    }

    try
    {
        # Grant the permission
        $assignment = New-AzADServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $PrincipalId `
            -ResourceId $graphSP.Id `
            -AppRoleId $permission.RoleId
        if ($assignment)
        {
            Write-Host "Successfully granted: $($permission.Name)" -ForegroundColor Green
            $grantedCount++
        }
    }
    catch
    {
        Write-Host "Failed to grant: $($_.Exception.Message)" -ForegroundColor Red
        $failedCount++
        if ($_.Exception.Message -like "*Insufficient privileges*")
        {
            Write-Host "     You need Global Administrator or Privileged Role Administrator role" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Granted: $grantedCount" -ForegroundColor Green
Write-Host "Skipped (already assigned): $skippedCount" -ForegroundColor Gray
if ($failedCount -gt 0)
{
    Write-Host "Failed: $failedCount" -ForegroundColor Red
}

if ($grantedCount -gt 0 -or $skippedCount -gt 0)
{
    Write-Host "`nThe managed identity now has the required permissions!" -ForegroundColor Green
    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "1. Create the Graph subscription: .\create-api-subscription-topic.ps1" -ForegroundColor White
    Write-Host "2. Deploy the Function App: func azure functionapp publish groupchangefunction" -ForegroundColor White
    Write-Host "3. Test the auto-renewal function if you created one" -ForegroundColor White
}
else
{
    Write-Host "`nNo permissions were granted. Please check the errors above." -ForegroundColor Yellow
}

Write-Host ""
