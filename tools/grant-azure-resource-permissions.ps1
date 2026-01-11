<#
.SYNOPSIS
    Grants Azure resource access permissions to the Function App's managed identity.

.DESCRIPTION
    This script assigns the required Azure role-based access control (RBAC) permissions to the
    user-assigned or system-assigned managed identity used by the Function App. This enables the
    function to access Azure resources using managed identity authentication instead of connection strings.

    The script assigns roles for:
    - Storage Account: Queue, Blob, and Table Data Contributor roles
    - Application Insights: Monitoring Metrics Publisher role
    - EventGrid Partner Topic: EventGrid Data Sender role (optional)

.PARAMETER ManagedIdentityName
    The name of the user-assigned managed identity. Leave empty for system-assigned identity.
    Default: "groupchangefunction-identities-9bef22"

.PARAMETER PrincipalId
    The principal (object) ID of the managed identity. If not provided, the script will attempt
    to retrieve it from the Function App configuration.
    Default: "" (auto-detect)

.PARAMETER FunctionAppName
    The name of the Function App that uses the managed identity.
    Default: "groupchangefunction"

.PARAMETER ResourceGroupName
    The name of the resource group containing the Azure resources.
    Default: "groupchangefunction"

.PARAMETER SubscriptionId
    The Azure subscription ID containing the resources.
    Default: "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"

.PARAMETER StorageAccountName
    The name of the Storage Account to grant access to.
    Default: "groupchangefunction1"

.PARAMETER ApplicationInsightsName
    The name of the Application Insights instance. Leave empty to auto-detect from function app settings.
    Default: "" (auto-detect)

.PARAMETER EventGridTopicName
    The name of the EventGrid partner topic. Leave empty to skip EventGrid permissions.
    Default: "" (skip EventGrid)

.PARAMETER SkipStoragePermissions
    Switch to skip granting Storage Account permissions.

.PARAMETER SkipAppInsightsPermissions
    Switch to skip granting Application Insights permissions.

.PARAMETER SkipEventGridPermissions
    Switch to skip granting EventGrid permissions.

.EXAMPLE
    .\grant-azure-resource-permissions.ps1
    Grants all permissions using default values with auto-detection

.EXAMPLE
    .\grant-azure-resource-permissions.ps1 -PrincipalId "e4ad71a2-53c3-467f-a553-bc7eebf711b5"
    Grants permissions to a specific managed identity

.EXAMPLE
    .\grant-azure-resource-permissions.ps1 -SkipEventGridPermissions
    Grants Storage and Application Insights permissions only

.EXAMPLE
    .\grant-azure-resource-permissions.ps1 -EventGridTopicName "groupchangefunctiontopic"
    Grants all permissions including EventGrid

.NOTES
    Prerequisites:
    - Azure CLI must be installed and configured: https://learn.microsoft.com/cli/azure/install-azure-cli
    - User must be logged in to Azure: az login
    - User must have sufficient permissions to create role assignments (Owner or User Access Administrator role)

    Required Roles:
    - Storage Account: Storage Queue Data Contributor, Storage Blob Data Contributor, Storage Table Data Contributor
    - Application Insights: Monitoring Metrics Publisher
    - EventGrid: EventGrid Data Sender (optional)

    Related Scripts:
    - grant-graph-permissions.ps1 - Grants Microsoft Graph API permissions (separate from Azure RBAC)
    - diagnose-eventgrid.ps1 - Diagnoses permission issues and validates configuration

.LINK
    https://learn.microsoft.com/azure/role-based-access-control/role-assignments-cli
    https://learn.microsoft.com/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity
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
    [string]$SubscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b",
    [Parameter()]
    [string]$StorageAccountName = "groupchangefunctionapp",
    [Parameter()]
    [string]$ApplicationInsightsName = "",
    [Parameter()]
    [string]$EventGridTopicName = "groupFunctionPartnerAppTopic",
    [Parameter()]
    [switch]$SkipStoragePermissions,
    [Parameter()]
    [switch]$SkipAppInsightsPermissions,
    [Parameter()]
    [switch]$SkipEventGridPermissions
)

$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Grant Azure Resource Permissions to Managed Identity" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Function App: $FunctionAppName" -ForegroundColor Gray
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Gray
Write-Host "  Storage Account: $StorageAccountName" -ForegroundColor Gray
Write-Host "  Application Insights: $(if ($ApplicationInsightsName) { $ApplicationInsightsName } else { '[Auto-detect]' })" -ForegroundColor Gray
Write-Host "  EventGrid Topic: $(if ($EventGridTopicName) { $EventGridTopicName } else { '[Skip]' })" -ForegroundColor Gray
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

function Test-RoleAssignment()
{
    param(
        [string]$PrincipalId,
        [string]$RoleName,
        [string]$Scope
    )

    try
    {
        $existingAssignments = az role assignment list `
            --assignee $PrincipalId `
            --role $RoleName `
            --scope $Scope `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            return $false
        }

        $assignments = $existingAssignments | ConvertFrom-Json
        return ($assignments.Count -gt 0)
    }
    catch
    {
        return $false
    }
}

function Grant-RoleAssignment()
{
    param(
        [string]$PrincipalId,
        [string]$RoleName,
        [string]$Scope,
        [string]$Description
    )

    Write-Host "`nGranting: $RoleName" -ForegroundColor Yellow
    Write-Host "  Description: $Description" -ForegroundColor Gray
    Write-Host "  Scope: $Scope" -ForegroundColor Gray

    # Check if already assigned
    $alreadyAssigned = Test-RoleAssignment -PrincipalId $PrincipalId -RoleName $RoleName -Scope $Scope

    if ($alreadyAssigned)
    {
        Write-Host "  Status: Already assigned (skipping)" -ForegroundColor Green
        return @{ Success = $true; Skipped = $true }
    }

    try
    {
        $result = az role assignment create `
            --assignee $PrincipalId `
            --role $RoleName `
            --scope $Scope `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            Write-Host "  Status: Failed" -ForegroundColor Red
            Write-Host "  Error: $result" -ForegroundColor Red

            if ($result -like "*Insufficient privileges*")
            {
                Write-Host "  Note: You need Owner or User Access Administrator role" -ForegroundColor Yellow
            }

            return @{ Success = $false; Error = $result }
        }

        Write-Host "  Status: Successfully granted" -ForegroundColor Green
        return @{ Success = $true; Skipped = $false }
    }
    catch
    {
        Write-Host "  Status: Failed" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-FunctionAppSettings()
{
    param(
        [string]$FunctionAppName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId
    )

    try
    {
        $settings = az functionapp config appsettings list `
            --name $FunctionAppName `
            --resource-group $ResourceGroupName `
            --subscription $SubscriptionId `
            -o json 2>&1
        if ($LASTEXITCODE -ne 0)
        {
            return $null
        }

        return ($settings | ConvertFrom-Json)
    }
    catch
    {
        return $null
    }
}

function Get-ApplicationInsightsResource()
{
    param(
        [string]$FunctionAppName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId,
        [string]$ApplicationInsightsName
    )

    try
    {
        # If name is provided, try to get that specific resource
        if ($ApplicationInsightsName)
        {
            Write-Host "  Searching for Application Insights by name: $ApplicationInsightsName" -ForegroundColor Gray
            $appInsightsJson = az resource show `
                --name $ApplicationInsightsName `
                --resource-group $ResourceGroupName `
                --resource-type "Microsoft.Insights/components" `
                --subscription $SubscriptionId `
                -o json 2>&1

            if ($LASTEXITCODE -eq 0)
            {
                return ($appInsightsJson | ConvertFrom-Json)
            }
        }

        # Try to auto-detect from function app settings (same logic as diagnose-eventgrid.ps1)
        Write-Host "  Auto-detecting Application Insights from Function App settings..." -ForegroundColor Gray
        $appSettings = Get-FunctionAppSettings -FunctionAppName $FunctionAppName -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId

        if ($null -eq $appSettings)
        {
            Write-Host "  Could not retrieve Function App settings" -ForegroundColor Yellow
            return $null
        }

        $appInsightsConnectionString = ($appSettings | Where-Object { $_.name -eq "APPLICATIONINSIGHTS_CONNECTION_STRING" }).value

        if (-not $appInsightsConnectionString)
        {
            Write-Host "  No Application Insights connection string found in app settings" -ForegroundColor Yellow
            return $null
        }

        # Extract instrumentation key or ApplicationId from connection string
        $instrumentationKey = $null
        $applicationId = $null

        if ($appInsightsConnectionString -match "InstrumentationKey=([^;]+)")
        {
            $instrumentationKey = $Matches[1]
            Write-Host "  Found Instrumentation Key: $($instrumentationKey.Substring(0, 8))..." -ForegroundColor Gray
        }

        if ($appInsightsConnectionString -match "ApplicationId=([^;]+)")
        {
            $applicationId = $Matches[1]
            Write-Host "  Found Application ID: $applicationId" -ForegroundColor Gray
        }

        # Try to find the Application Insights resource in the same resource group
        $appInsightsResources = az resource list `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroupName `
            --resource-type "Microsoft.Insights/components" `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0 -or -not $appInsightsResources -or $appInsightsResources -eq "[]")
        {
            Write-Host "  No Application Insights resources found in resource group" -ForegroundColor Yellow
            return $null
        }

        $componentsInRG = $appInsightsResources | ConvertFrom-Json
        $appInsights = $null

        # Try to match by ApplicationId if available
        if ($applicationId -and $componentsInRG.Count -gt 0)
        {
            Write-Host "  Searching for Application Insights by Application ID..." -ForegroundColor Gray
            foreach ($component in $componentsInRG)
            {
                $detailsJson = az resource show --ids $component.id -o json 2>&1
                if ($LASTEXITCODE -eq 0)
                {
                    $details = $detailsJson | ConvertFrom-Json
                    if ($details.properties.AppId -eq $applicationId)
                    {
                        $appInsights = $details
                        Write-Host "  Matched Application Insights by Application ID" -ForegroundColor Green
                        break
                    }
                }
            }
        }

        # If no match yet and only one component in RG, use it
        if (-not $appInsights -and $componentsInRG.Count -eq 1)
        {
            Write-Host "  Found single Application Insights resource in resource group" -ForegroundColor Gray
            $detailsJson = az resource show --ids $componentsInRG[0].id -o json 2>&1
            if ($LASTEXITCODE -eq 0)
            {
                $appInsights = $detailsJson | ConvertFrom-Json
            }
        }

        # If still no match and we have an instrumentation key, try matching by InstrumentationKey
        if (-not $appInsights -and $instrumentationKey -and $componentsInRG.Count -gt 0)
        {
            Write-Host "  Searching for Application Insights by Instrumentation Key..." -ForegroundColor Gray
            foreach ($component in $componentsInRG)
            {
                $detailsJson = az resource show --ids $component.id -o json 2>&1
                if ($LASTEXITCODE -eq 0)
                {
                    $details = $detailsJson | ConvertFrom-Json
                    if ($details.properties.InstrumentationKey -eq $instrumentationKey)
                    {
                        $appInsights = $details
                        Write-Host "  Matched Application Insights by Instrumentation Key" -ForegroundColor Green
                        break
                    }
                }
            }
        }

        return $appInsights
    }
    catch
    {
        Write-Host "  Error searching for Application Insights: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}
#endregion

#region Step 1: Get or Validate Principal ID
Write-Host "`n[Step 1] Retrieving Managed Identity Principal ID" -ForegroundColor Cyan
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
#endregion

#region Step 2: Grant Storage Account Permissions
if (-not $SkipStoragePermissions)
{
    Write-Host "`n`n[Step 2] Granting Storage Account Permissions" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    $storageAccountScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"

    # Define required storage roles
    $storageRoles = @(
        @{
            Name        = "Storage Queue Data Contributor"
            Description = "Read, write, and delete Azure Storage queues and queue messages"
            RoleId      = "974c5e8b-45b9-4653-ba55-5f855dd0fb88"
        },
        @{
            Name        = "Storage Blob Data Contributor"
            Description = "Read, write, and delete Azure Storage containers and blobs"
            RoleId      = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
        },
        @{
            Name        = "Storage Table Data Contributor"
            Description = "Read, write, and delete Azure Storage tables and table entities"
            RoleId      = "0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3"
        }
    )

    $storageResults = @()
    foreach ($role in $storageRoles)
    {
        $result = Grant-RoleAssignment `
            -PrincipalId $PrincipalId `
            -RoleName $role.Name `
            -Scope $storageAccountScope `
            -Description $role.Description

        $storageResults += @{
            RoleName = $role.Name
            Success  = $result.Success
            Skipped  = $result.Skipped
            Error    = $result.Error
        }
    }

    Write-Host "`nStorage Account Permissions Summary:" -ForegroundColor Cyan
    $granted = ($storageResults | Where-Object { $_.Success -and -not $_.Skipped }).Count
    $skipped = ($storageResults | Where-Object { $_.Skipped }).Count
    $failed = ($storageResults | Where-Object { -not $_.Success }).Count

    Write-Host "  Granted: $granted" -ForegroundColor Green
    Write-Host "  Already Assigned: $skipped" -ForegroundColor Gray
    if ($failed -gt 0)
    {
        Write-Host "  Failed: $failed" -ForegroundColor Red
    }
}
else
{
    Write-Host "`n`n[Step 2] Skipping Storage Account Permissions (SkipStoragePermissions flag set)" -ForegroundColor Yellow
}
#endregion

#region Step 3: Grant Application Insights Permissions
if (-not $SkipAppInsightsPermissions)
{
    Write-Host "`n`n[Step 3] Granting Application Insights Permissions" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    $appInsights = Get-ApplicationInsightsResource `
        -FunctionAppName $FunctionAppName `
        -ResourceGroupName $ResourceGroupName `
        -SubscriptionId $SubscriptionId `
        -ApplicationInsightsName $ApplicationInsightsName

    if ($null -eq $appInsights)
    {
        Write-Host "Warning: Application Insights resource not found" -ForegroundColor Yellow
        Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
        if ($ApplicationInsightsName)
        {
            Write-Host "  Application Insights Name: $ApplicationInsightsName" -ForegroundColor Gray
        }
        Write-Host "  Skipping Application Insights permissions..." -ForegroundColor Yellow
    }
    else
    {
        Write-Host "Found Application Insights:" -ForegroundColor Green
        Write-Host "  Name: $($appInsights.name)" -ForegroundColor Gray
        Write-Host "  Resource ID: $($appInsights.id)" -ForegroundColor Gray

        $appInsightsResult = Grant-RoleAssignment `
            -PrincipalId $PrincipalId `
            -RoleName "Monitoring Metrics Publisher" `
            -Scope $appInsights.id `
            -Description "Publish metrics to Azure Monitor"

        Write-Host "`nApplication Insights Permissions Summary:" -ForegroundColor Cyan
        if ($appInsightsResult.Success)
        {
            if ($appInsightsResult.Skipped)
            {
                Write-Host "  Status: Already assigned" -ForegroundColor Green
            }
            else
            {
                Write-Host "  Status: Successfully granted" -ForegroundColor Green
            }
        }
        else
        {
            Write-Host "  Status: Failed" -ForegroundColor Red
        }
    }
}
else
{
    Write-Host "`n`n[Step 3] Skipping Application Insights Permissions (SkipAppInsightsPermissions flag set)" -ForegroundColor Yellow
}
#endregion

#region Step 4: Grant EventGrid Permissions
if (-not $SkipEventGridPermissions -and -not [string]::IsNullOrEmpty($EventGridTopicName))
{
    Write-Host "`n`n[Step 4] Granting EventGrid Permissions" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    $eventGridScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.EventGrid/partnerTopics/$EventGridTopicName"

    # Check if EventGrid partner topic exists
    $topicJson = az eventgrid partner topic show `
        --name $EventGridTopicName `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        -o json 2>$null

    if ($LASTEXITCODE -ne 0)
    {
        Write-Host "Warning: EventGrid partner topic not found: $EventGridTopicName" -ForegroundColor Yellow
        Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
        Write-Host "  Note: EventGrid permissions typically not required for receiving events" -ForegroundColor Gray
        Write-Host "  Skipping EventGrid permissions..." -ForegroundColor Yellow
    }
    else
    {
        Write-Host "Found EventGrid Partner Topic:" -ForegroundColor Green
        Write-Host "  Name: $EventGridTopicName" -ForegroundColor Gray

        $eventGridResult = Grant-RoleAssignment `
            -PrincipalId $PrincipalId `
            -RoleName "EventGrid Data Sender" `
            -Scope $eventGridScope `
            -Description "Send events to EventGrid topics"

        Write-Host "`nEventGrid Permissions Summary:" -ForegroundColor Cyan
        if ($eventGridResult.Success)
        {
            if ($eventGridResult.Skipped)
            {
                Write-Host "  Status: Already assigned" -ForegroundColor Green
            }
            else
            {
                Write-Host "  Status: Successfully granted" -ForegroundColor Green
            }
        }
        else
        {
            Write-Host "  Status: Failed" -ForegroundColor Red
            Write-Host "  Note: This role may not be necessary for receiving events via EventGrid trigger" -ForegroundColor Gray
        }
    }
}
else
{
    if ($SkipEventGridPermissions)
    {
        Write-Host "`n`n[Step 4] Skipping EventGrid Permissions (SkipEventGridPermissions flag set)" -ForegroundColor Yellow
    }
    else
    {
        Write-Host "`n`n[Step 4] Skipping EventGrid Permissions (No topic name provided)" -ForegroundColor Yellow
        Write-Host "  Note: EventGrid permissions are typically not required for receiving events" -ForegroundColor Gray
        Write-Host "  Use -EventGridTopicName parameter if you need to grant EventGrid Data Sender role" -ForegroundColor Gray
    }
}
#endregion

#region Final Summary
Write-Host "`n`n================================================================" -ForegroundColor Cyan
Write-Host "Final Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

Write-Host "`nManaged Identity: $PrincipalId" -ForegroundColor Green

if (-not $SkipStoragePermissions)
{
    Write-Host "`nStorage Account Permissions:" -ForegroundColor Cyan
    Write-Host "  Resource: $StorageAccountName" -ForegroundColor Gray
    Write-Host "  Roles: Queue, Blob, and Table Data Contributor" -ForegroundColor Gray
}

if (-not $SkipAppInsightsPermissions)
{
    Write-Host "`nApplication Insights Permissions:" -ForegroundColor Cyan
    if ($appInsights)
    {
        Write-Host "  Resource: $($appInsights.name)" -ForegroundColor Gray
        Write-Host "  Role: Monitoring Metrics Publisher" -ForegroundColor Gray
    }
    else
    {
        Write-Host "  Status: Not configured (resource not found)" -ForegroundColor Yellow
    }
}

if (-not $SkipEventGridPermissions -and -not [string]::IsNullOrEmpty($EventGridTopicName))
{
    Write-Host "`nEventGrid Permissions:" -ForegroundColor Cyan
    Write-Host "  Resource: $EventGridTopicName" -ForegroundColor Gray
    Write-Host "  Role: EventGrid Data Sender" -ForegroundColor Gray
}

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Grant Microsoft Graph permissions: .\tools\grant-graph-permissions.ps1" -ForegroundColor White
Write-Host "2. Create Graph subscription: .\tools\create-api-subscription-topic.ps1" -ForegroundColor White
Write-Host "3. Verify configuration: .\tools\diagnose-eventgrid.ps1" -ForegroundColor White
Write-Host "4. Deploy Function App: func azure functionapp publish $FunctionAppName" -ForegroundColor White

Write-Host ""
#endregion
