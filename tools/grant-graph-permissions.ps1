<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to the Function App's user-assigned managed identity.

.DESCRIPTION
    This script assigns the required Microsoft Graph application permissions to the user-assigned
    managed identity used by the Function App. This allows the RenewSubscription function to
    automatically renew Graph API subscriptions using the managed identity.

.PARAMETER ManagedIdentityName
    The name of the user-assigned managed identity. Leave empty for auto-detection.
    Default: "groupFunctionApp-identities-82cd94"

.PARAMETER PrincipalId
    The principal (object) ID of the managed identity. If not provided, the script will attempt
    to retrieve it from the Function App configuration.
    Default: "" (auto-detect)

.PARAMETER FunctionAppName
    The name of the Function App that uses the managed identity.
    Default: "groupChangeFunctionApp"

.PARAMETER ResourceGroupName
    The name of the resource group containing the Function App.
    Default: "groupFunctionApp"

.PARAMETER SubscriptionId
    The Azure subscription ID containing the resources.
    Default: "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"

.EXAMPLE
    .\grant-graph-permissions.ps1
    Grants permissions using auto-detection from Function App

.EXAMPLE
    .\grant-graph-permissions.ps1 -PrincipalId "e4ad71a2-53c3-467f-a553-bc7eebf711b5"
    Grants permissions to a specific managed identity

.NOTES
    Prerequisites:
    - Az.Accounts module
    - Az.Resources module
    - Azure CLI (for auto-detection)
    - Global Administrator or Privileged Role Administrator role in Entra ID

    Related Scripts:
    - grant-azure-resource-permissions.ps1 - Grants Azure RBAC permissions
    - diagnose-eventgrid.ps1 - Diagnoses permission issues and validates configuration
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManagedIdentityName = "groupFunctionApp-identities-82cd94",
    [Parameter()]
    [string]$PrincipalId = "",
    [Parameter()]
    [string]$FunctionAppName = "groupChangeFunctionApp",
    [Parameter()]
    [string]$ResourceGroupName = "groupFunctionApp",
    [Parameter()]
    [string]$SubscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"
)

$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Grant Microsoft Graph Permissions to Managed Identity" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Function App: $FunctionAppName" -ForegroundColor Gray
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Gray
Write-Host "  Managed Identity Name: $ManagedIdentityName" -ForegroundColor Gray
Write-Host "  Principal ID: $(if ($PrincipalId) { $PrincipalId } else { '[Auto-detect]' })" -ForegroundColor Gray
Write-Host ""

#region Helper Functions
function Get-ManagedIdentityPrincipalId()
{
    param(
        [string]$FunctionAppName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId
    )

    Write-Host "Retrieving managed identity configuration..." -ForegroundColor Cyan

    try
    {
        $identityJson = az functionapp identity show `
            --name $FunctionAppName `
            --resource-group $ResourceGroupName `
            --subscription $SubscriptionId `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            throw "Failed to retrieve function app identity: $identityJson"
        }

        $identity = $identityJson | ConvertFrom-Json

        # Check identity type
        if ($identity.type -eq "UserAssigned")
        {
            $userAssignedIdentities = @($identity.userAssignedIdentities.PSObject.Properties)
            if ($userAssignedIdentities.Count -gt 0)
            {
                $firstIdentity = $userAssignedIdentities[0].Value
                $principalId = $firstIdentity.principalId
                $clientId = $firstIdentity.clientId

                Write-Host "  Identity Type: User-Assigned Managed Identity" -ForegroundColor Green
                Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
                Write-Host "  Client ID: $clientId" -ForegroundColor Gray

                return $principalId
            }
        }
        elseif ($identity.type -like "*SystemAssigned*")
        {
            $principalId = $identity.principalId
            Write-Host "  Identity Type: System-Assigned Managed Identity" -ForegroundColor Green
            Write-Host "  Principal ID: $principalId" -ForegroundColor Gray

            return $principalId
        }
        else
        {
            throw "No managed identity configured for Function App: $FunctionAppName"
        }
    }
    catch
    {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}
#endregion

#region Step 0: Get or Validate Principal ID
Write-Host "`n[Step 0] Retrieving Managed Identity Principal ID" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ([string]::IsNullOrEmpty($PrincipalId))
{
    Write-Host "No Principal ID provided. Auto-detecting from Function App..." -ForegroundColor Yellow
    try
    {
        $PrincipalId = Get-ManagedIdentityPrincipalId `
            -FunctionAppName $FunctionAppName `
            -ResourceGroupName $ResourceGroupName `
            -SubscriptionId $SubscriptionId
    }
    catch
    {
        Write-Host "`nFailed to retrieve managed identity. Please provide -PrincipalId parameter." -ForegroundColor Red
        exit 1
    }
}
else
{
    Write-Host "Using provided Principal ID: $PrincipalId" -ForegroundColor Green
}

if ([string]::IsNullOrEmpty($PrincipalId))
{
    Write-Host "`nError: No Principal ID available. Cannot proceed." -ForegroundColor Red
    exit 1
}
Write-Host ""
#endregion

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
    },
    @{
        Name        = "User.Read.All"
        Description = "Read all users"
    },
    @{
        Name        = "Group.Read.All"
        Description = "Read all groups (for subscription resource)"
    },
    @{
        Name        = "Directory.Read.All"
        Description = "Read directory data (for subscription management)"
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
    Write-Host "1. Grant Azure RBAC permissions: .\tools\grant-azure-resource-permissions.ps1" -ForegroundColor White
    Write-Host "2. Create the Graph subscription: .\tools\create-api-subscription-topic.ps1" -ForegroundColor White
    Write-Host "3. Deploy the Function App: func azure functionapp publish $FunctionAppName" -ForegroundColor White
    Write-Host "4. Verify configuration: .\tools\diagnose-eventgrid.ps1" -ForegroundColor White
}
else
{
    Write-Host "`nNo permissions were granted. Please check the errors above." -ForegroundColor Yellow
}

Write-Host ""
