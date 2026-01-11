<#
.SYNOPSIS
    Diagnoses EventGrid event delivery issues and managed identity permissions for Microsoft Graph subscriptions.

.DESCRIPTION
    This script performs comprehensive diagnostics on Microsoft Graph change notification subscriptions
    configured to send events to Azure EventGrid. It examines:
    - Managed identity configuration (user-assigned vs system-assigned)
    - Managed identity permissions on all required resources:
      * Storage Account (Queue, Blob, Table access)
      * Application Insights (write access for telemetry)
      * Microsoft Graph API (required Graph permissions)
      * EventGrid (event delivery)
    - Graph subscription configuration and expiration status
    - EventGrid partner topic activation state
    - Event subscription configuration and delivery settings
    - EventGrid metrics (published, matched, and delivered events)
    - Provides specific diagnosis and remediation guidance

    The script automatically discovers EventGrid-based subscriptions or uses a provided subscription ID.
    It validates prerequisites (resource group existence) and provides detailed error messages when
    resources are missing or misconfigured.

.PARAMETER graphSubscriptionId
    The Microsoft Graph subscription ID to diagnose. If not provided or if the provided ID is not
    found, the script will automatically search for all active EventGrid-based subscriptions and
    examine each one. Useful when you want to diagnose a specific subscription or perform auto-discovery.
    Default: "" (auto-discover)

.PARAMETER topicName
    The name of the EventGrid partner topic. This topic receives events from Microsoft Graph
    change notifications. Used to check topic activation state, event subscriptions, and metrics.
    Default: "groupchangefunctiontopic"

.PARAMETER subscriptionId
    The Azure subscription ID where the EventGrid partner topic and related resources reside.
    This is different from the Graph subscription ID and is required to query Azure resources.
    Default: "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"

.PARAMETER resourceGroupName
    The Azure resource group containing the EventGrid partner topic and event subscriptions.
    The script validates this resource group exists before performing diagnostics.
    Default: "groupchangefunction"

.PARAMETER functionAppName
    The name of the Function App that the EventGrid partner topic sends events to.
    Used to locate and validate the event subscription configuration and managed identity permissions.
    Default: "groupchangefunction"

.PARAMETER storageAccountName
    The name of the Storage Account used by the function app for queues, blobs, and tables.
    Used to verify managed identity has required storage permissions.
    Default: "groupchangefunction1"

.PARAMETER eventTimeDays
    Number of days of historical metrics to retrieve and analyze (default: 1 day).
    Useful for checking metrics over longer periods when diagnosing intermittent issues.
    Default: 1

.PARAMETER SkipPermissionChecks
    Switch to skip managed identity permission checks. Use this to speed up the script
    when you only want to check EventGrid configuration and metrics.
    Default: $false

.EXAMPLE
    .\diagnose-eventgrid.ps1
    Performs auto-discovery of EventGrid subscriptions, checks managed identity permissions,
    and diagnoses all found subscriptions using default parameter values.

.EXAMPLE
    .\diagnose-eventgrid.ps1 -SkipPermissionChecks
    Performs diagnostics without checking managed identity permissions (faster execution).

.EXAMPLE
    .\diagnose-eventgrid.ps1 -graphSubscriptionId "69b82601-c3c8-446f-a72c-2384784cd404"
    Diagnoses a specific Graph subscription and checks its EventGrid configuration and permissions.

.EXAMPLE
    .\diagnose-eventgrid.ps1 -graphSubscriptionId "69b82601-c3c8-446f-a72c-2384784cd404" `
        -resourceGroupName "myResourceGroup" -topicName "myTopic" -functionAppName "myFunction" `
        -storageAccountName "mystorageaccount"
    Diagnoses a specific subscription with custom Azure resource names.

.EXAMPLE
    .\diagnose-eventgrid.ps1 -eventTimeDays 7
    Auto-discovers subscriptions and checks metrics from the last 7 days.

.NOTES
    Prerequisites:
    - Microsoft Graph PowerShell module must be installed: Install-Module Microsoft.Graph
    - Azure CLI must be installed and configured: https://learn.microsoft.com/cli/azure/install-azure-cli
    - User must be authenticated to both Microsoft Graph and Azure:
      * Connect-MgGraph (for Graph API access)
      * az login (for Azure resources)

    Permission Checks:
    - The script verifies managed identity (user-assigned or system-assigned) configuration
    - Checks role assignments for:
      * Storage Account (Queue, Blob, Table Data Contributor roles)
      * Application Insights (Monitoring Metrics Publisher)
      * Microsoft Graph API (Group.Read.All, User.Read.All, Device.Read.All)
      * EventGrid (event delivery permissions)
    - Use -SkipPermissionChecks to skip permission verification (faster execution)

    Error Handling:
    - Step 0 validates the resource group exists before attempting dependent operations
    - Missing or misconfigured resources are reported with actionable troubleshooting steps
    - Detailed error messages include the specific parameters being searched for
    - Sections are skipped gracefully if prerequisites are not met

    Troubleshooting Guide:
    - If no Graph subscriptions found: Use create-api-subscription-topic.ps1 to create one
    - If resource group not found: Verify subscription ID and resource group name
    - If partner topic not found: Check that topic exists in the specified resource group
    - If no event subscriptions found: Verify function app name and topic configuration
    - If metrics are unavailable: Ensure at least one day has passed since resource creation
    - If managed identity permissions missing: Check output for specific remediation steps

    Related Scripts:
    - create-api-subscription-topic.ps1 - Creates new Graph subscription and EventGrid topic
    - grant-graph-permissions.ps1 - Grants Graph API permissions to managed identity
    - check-subscription.ps1 - Lists all Graph subscriptions
    - renew-subscription.ps1 - Manually renews a Graph subscription
    - Verify-StorageAuth.ps1 - Standalone storage authentication verification

.LINK
    https://learn.microsoft.com/en-us/graph/api/subscription-post-subscriptions
    https://learn.microsoft.com/en-us/azure/event-grid/concepts
#>
[CmdletBinding()]
param(
    [string]$graphSubscriptionId = "",
    [string]$topicName = "groupFunctionPartnerAppTopic",
    [string]$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b",
    [string]$functionAppName = "groupChangeFunctionApp",
    [string]$resourceGroupName = "groupFunctionApp",
    [string]$storageAccountName = "groupchangefunctionapp",
    [int]$eventTimeDays = 1,
    [switch]$SkipPermissionChecks
)

#region initial output and connection check
Write-Host "=== EventGrid Diagnostics ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Using the following parameters:" -ForegroundColor Cyan
Write-Host " Graph Subscription ID: $(if ([string]::IsNullOrEmpty($graphSubscriptionId)) { '[AUTO-DETECT]' } else { $graphSubscriptionId })" -ForegroundColor Gray
Write-Host " EventGrid Topic Name: $topicName" -ForegroundColor Gray
Write-Host " Resource Group Name: $resourceGroupName" -ForegroundColor Gray
Write-Host " Function App Name: $functionAppName" -ForegroundColor Gray
Write-Host " Storage Account Name: $storageAccountName" -ForegroundColor Gray
Write-Host " Subscription ID: $subscriptionId" -ForegroundColor Gray
Write-Host " Skip Permission Checks: $SkipPermissionChecks" -ForegroundColor Gray
Write-Host ""
try
{
    $context = Get-MgContext
    if (-not $context)
    {
        Write-Host "   Connecting to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes "Subscription.Read.All" -NoWelcome
        $context = Get-MgContext
        Write-Host "   Connected as: $($context.Account)" -ForegroundColor Gray
    }
    else
    {
        Write-Host "Already connected as: $($context.Account)" -ForegroundColor Gray
    }
}
catch
{
    Write-Host "Error connecting to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
#endregion initial output and connection check

#region helper functions
# Function to find all valid EventGrid-based graph subscriptions
function Find-ValidEventGridSubscriptions()
{
    param()

    try
    {
        $allSubs = Get-MgSubscription -All

        if ($allSubs.Count -eq 0)
        {
            return @()
        }

        # Look for subscriptions configured with EventGrid notification URLs
        $eventGridSubs = $allSubs | Where-Object { $_.NotificationUrl -like "*eventgrid*" }

        if ($eventGridSubs)
        {
            # Return all non-expired EventGrid-based subscriptions
            $validSubs = $eventGridSubs | Where-Object {
                $expiration = [DateTime]::Parse($_.ExpirationDateTime)
                $expiration -gt (Get-Date)
            }

            return @($validSubs)
        }

        return @()
    }
    catch
    {
        Write-Host "Error searching for subscriptions: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

# Function to validate Azure resource group exists
function Test-ResourceGroupExists()
{
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName
    )

    try
    {
        $result = az group exists `
            --subscription $SubscriptionId `
            --name $ResourceGroupName

        return ($result.Trim() -eq "true")
    }
    catch
    {
        return $false
    }
}

# Function to get managed identity configuration
function Get-ManagedIdentityConfig()
{
    param(
        [string]$FunctionAppName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId
    )

    try
    {
        $identityInfo = az functionapp identity show `
            --name $FunctionAppName `
            --resource-group $ResourceGroupName `
            --subscription $SubscriptionId `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            return $null
        }

        $identity = $identityInfo | ConvertFrom-Json
        return $identity
    }
    catch
    {
        return $null
    }
}

# Function to get app settings
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

# Function to check role assignments for a principal
function Get-RoleAssignments()
{
    param(
        [string]$PrincipalId,
        [string]$Scope,
        [string]$SubscriptionId
    )

    try
    {
        $assignments = az role assignment list `
            --assignee $PrincipalId `
            --scope $Scope `
            --subscription $SubscriptionId `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            return @()
        }

        return ($assignments | ConvertFrom-Json)
    }
    catch
    {
        return @()
    }
}

# Function to check Microsoft Graph API permissions
function Test-GraphApiPermissions()
{
    param(
        [string]$PrincipalId
    )

    try
    {
        # Get service principal for the managed identity
        $spInfo = az ad sp show --id $PrincipalId -o json 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            return @{
                HasAccess   = $false
                Error       = "Unable to retrieve service principal information"
                Permissions = @()
            }
        }

        $sp = $spInfo | ConvertFrom-Json

        # Get Microsoft Graph service principal first to get its object ID
        $graphAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph App ID
        $graphSpJson = az ad sp show --id $graphAppId -o json 2>&1
        if ($LASTEXITCODE -ne 0)
        {
            return @{
                HasAccess   = $false
                Error       = "Unable to retrieve Microsoft Graph service principal"
                Permissions = @()
            }
        }

        $graphSp = $graphSpJson | ConvertFrom-Json
        $graphObjectId = $graphSp.id  # This is the object ID we need for filtering

        # Get app role assignments for Microsoft Graph
        $appRoleAssignments = az rest `
            --method GET `
            --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" `
            --headers "Content-Type=application/json" `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            return @{
                HasAccess   = $false
                Error       = "Unable to retrieve app role assignments"
                Permissions = @()
            }
        }

        $assignments = ($appRoleAssignments | ConvertFrom-Json).value
        # Filter by the Graph service principal's object ID (not application ID)
        $graphAssignments = $assignments | Where-Object { $_.resourceId -eq $graphObjectId }
        $permissions = @()

        foreach ($assignment in $graphAssignments)
        {
            $role = $graphSp.appRoles | Where-Object { $_.id -eq $assignment.appRoleId }
            if ($role)
            {
                $permissions += $role.value
            }
        }

        # Check for required permissions
        $requiredPermissions = @(
            "Group.Read.All",
            "User.Read.All",
            "Device.ReadWrite.All",  # ReadWrite.All includes Read.All
            "Directory.Read.All"
        )

        $missingPermissions = $requiredPermissions | Where-Object { $_ -notin $permissions }

        return @{
            HasAccess          = ($missingPermissions.Count -eq 0)
            Permissions        = $permissions
            MissingPermissions = $missingPermissions
        }
    }
    catch
    {
        return @{
            HasAccess   = $false
            Error       = $_.Exception.Message
            Permissions = @()
        }
    }
}
#endregion helper functions

# 1. Find all valid Graph Subscriptions
Write-Host "1. Discovering Microsoft Graph Subscriptions..." -ForegroundColor Yellow

$graphSubs = @()
# Try to use provided subscription ID first
if (-not [string]::IsNullOrEmpty($graphSubscriptionId))
{
    try
    {
        $foundSub = Get-MgSubscription -SubscriptionId $graphSubscriptionId
        $graphSubs += $foundSub
        Write-Host "Using provided Graph Subscription ID: $graphSubscriptionId" -ForegroundColor Green
    }
    catch
    {
        Write-Host "Provided subscription ID not found: $graphSubscriptionId" -ForegroundColor Yellow
        Write-Host "Searching for alternative EventGrid-based subscriptions..." -ForegroundColor Cyan
    }
}
else
{
    Write-Host "No subscription ID provided." -ForegroundColor Cyan

    # Check for subscription-info.json in project root before auto-detecting
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $subscriptionInfoPath = Join-Path $projectRoot "subscription-info.json"

    if (Test-Path $subscriptionInfoPath)
    {
        try
        {
            $subscriptionInfo = Get-Content $subscriptionInfoPath -Raw | ConvertFrom-Json
            if ($subscriptionInfo.SubscriptionId)
            {
                Write-Host "Found subscription-info.json file" -ForegroundColor Cyan
                Write-Host "Attempting to use subscription ID from file: $($subscriptionInfo.SubscriptionId)" -ForegroundColor Cyan

                $foundSub = Get-MgSubscription -SubscriptionId $subscriptionInfo.SubscriptionId
                if ($foundSub)
                {
                    $graphSubs += $foundSub
                    Write-Host "Successfully loaded subscription from subscription-info.json" -ForegroundColor Green
                }
            }
        }
        catch
        {
            Write-Host "Failed to load subscription from subscription-info.json: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($graphSubs.Count -eq 0)
    {
        Write-Host "Searching for EventGrid-based subscriptions..." -ForegroundColor Cyan
    }
}

# If we don't have subscriptions yet, search for valid ones
if ($graphSubs.Count -eq 0)
{
    $graphSubs = Find-ValidEventGridSubscriptions
    if ($graphSubs.Count -eq 0)
    {
        Write-Host "No valid EventGrid-based Graph subscriptions found." -ForegroundColor Red
        Write-Host "Please create a subscription using: .\create-api-subscription-topic.ps1" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

Write-Host "Found $($graphSubs.Count) subscription(s) to examine:" -ForegroundColor Cyan
foreach ($sub in $graphSubs)
{
    Write-Host "  - $($sub.Id)" -ForegroundColor Gray
}
Write-Host ""

# Validate prerequisites before checking each subscription
Write-Host "0. Validating prerequisites..." -ForegroundColor Yellow
$rgExists = Test-ResourceGroupExists -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName
if (-not $rgExists)
{
    Write-Host "ERROR: Resource Group not found" -ForegroundColor Red
    Write-Host "  Subscription ID: $subscriptionId" -ForegroundColor Gray
    Write-Host "  Resource Group Name: $resourceGroupName" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Please verify the following:" -ForegroundColor Yellow
    Write-Host "  1. Subscription ID is correct: $subscriptionId" -ForegroundColor Gray
    Write-Host "  2. Resource Group exists: $resourceGroupName" -ForegroundColor Gray
    Write-Host "  3. You have access to this subscription and resource group" -ForegroundColor Gray
    Write-Host "  4. Try listing your resource groups: az group list --output table" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Continuing with Graph subscription analysis only..." -ForegroundColor Yellow
    Write-Host ""
}
else
{
    Write-Host "Resource Group found: $resourceGroupName" -ForegroundColor Green
    Write-Host ""
}

# Check Managed Identity Configuration and Permissions
if (-not $SkipPermissionChecks -and $rgExists)
{
    Write-Host "0.1 Checking Managed Identity Configuration..." -ForegroundColor Yellow
    # Get managed identity configuration
    $identityConfig = Get-ManagedIdentityConfig -FunctionAppName $functionAppName -ResourceGroupName $resourceGroupName -SubscriptionId $subscriptionId
    if ($null -eq $identityConfig)
    {
        Write-Host "ERROR: Unable to retrieve managed identity configuration" -ForegroundColor Red
        Write-Host "  Function App: $functionAppName" -ForegroundColor Gray
        Write-Host "  Verify the function app exists and you have access" -ForegroundColor Yellow
        Write-Host ""
    }
    else
    {
        # Determine identity type and principal ID
        $identityType = $identityConfig.type
        $principalId = $null
        $clientId = $null
        $userPrincipalId = $null
        if ($identityType -eq "UserAssigned")
        {
            $userAssignedIdentities = @($identityConfig.userAssignedIdentities.PSObject.Properties)
            if ($userAssignedIdentities.Count -gt 0)
            {
                $firstIdentity = $userAssignedIdentities[0].Value
                $identityResourceId = $userAssignedIdentities[0].Name
                $principalId = $firstIdentity.principalId
                $clientId = $firstIdentity.clientId
                Write-Host "Identity Type: User-Assigned Managed Identity" -ForegroundColor Cyan
                Write-Host "  Identity Resource: $identityResourceId" -ForegroundColor Gray
                Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
                Write-Host "  Client ID: $clientId" -ForegroundColor Gray
            }
        }
        elseif ($identityType -eq "SystemAssigned" -or $identityType -eq "SystemAssigned, UserAssigned")
        {
            $principalId = $identityConfig.principalId
            Write-Host "Identity Type: System-Assigned Managed Identity" -ForegroundColor Cyan
            Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
            # Also check for user-assigned if both exist
            if ($identityType -eq "SystemAssigned, UserAssigned")
            {
                Write-Host "  Note: Function also has User-Assigned identity configured" -ForegroundColor Yellow
                $userAssignedIdentities = @($identityConfig.userAssignedIdentities.PSObject.Properties)
                if ($userAssignedIdentities.Count -gt 0)
                {
                    $firstIdentity = $userAssignedIdentities[0].Value
                    $userPrincipalId = $firstIdentity.principalId
                    $clientId = $firstIdentity.clientId
                    Write-Host "  User-Assigned Principal ID: $userPrincipalId" -ForegroundColor Gray
                    Write-Host "  User-Assigned Client ID: $clientId" -ForegroundColor Gray
                }
            }
        }
        else
        {
            Write-Host "Identity Type: None" -ForegroundColor Red
            Write-Host "  No managed identity is configured for this function app" -ForegroundColor Yellow
            Write-Host ""
        }

        if ($null -ne $principalId)
        {
            # Get app settings to determine which identity is being used
            Write-Host ""
            Write-Host "0.2 Checking App Settings..." -ForegroundColor Yellow
            $appSettings = Get-FunctionAppSettings -FunctionAppName $functionAppName -ResourceGroupName $resourceGroupName -SubscriptionId $subscriptionId
            if ($null -ne $appSettings)
            {
                $azureClientId = ($appSettings | Where-Object { $_.name -eq "AZURE_CLIENT_ID" }).value
                $storageCredential = ($appSettings | Where-Object { $_.name -eq "AzureWebJobsStorage__credential" }).value
                $storageClientId = ($appSettings | Where-Object { $_.name -eq "AzureWebJobsStorage__clientId" }).value
                if ($azureClientId)
                {
                    Write-Host "AZURE_CLIENT_ID: $azureClientId" -ForegroundColor Green
                    if ($clientId -and $azureClientId -eq $clientId)
                    {
                        Write-Host "Matches user-assigned managed identity" -ForegroundColor Green
                        # Update principalId to use the user-assigned identity
                        if ($identityType -eq "SystemAssigned, UserAssigned" -and $userPrincipalId)
                        {
                            $principalId = $userPrincipalId
                        }
                    }
                    elseif ($clientId)
                    {
                        Write-Host "Does NOT match user-assigned managed identity client ID" -ForegroundColor Yellow
                    }
                }
                else
                {
                    Write-Host "AZURE_CLIENT_ID: Not set (using system-assigned identity)" -ForegroundColor Cyan
                }
                if ($storageCredential)
                {
                    Write-Host "Storage Credential Type: $storageCredential" -ForegroundColor Green
                }
                if ($storageClientId)
                {
                    Write-Host "Storage Client ID: $storageClientId" -ForegroundColor Green
                }
                Write-Host ""
            }
            # Check Storage Account Permissions
            Write-Host "0.3 Checking Storage Account Permissions..." -ForegroundColor Yellow
            $storageScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
            $storageRoles = Get-RoleAssignments -PrincipalId $principalId -Scope $storageScope -SubscriptionId $subscriptionId
            $requiredStorageRoles = @{
                "Storage Queue Data Contributor" = "974c5e8b-45b9-4653-ba55-5f855dd0fb88"
                "Storage Blob Data Contributor"  = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
                "Storage Table Data Contributor" = "0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3"
            }
            $foundRoles = @()
            foreach ($role in $storageRoles)
            {
                $roleName = $role.roleDefinitionName
                $foundRoles += $roleName
            }
            foreach ($roleName in $requiredStorageRoles.Keys)
            {
                if ($foundRoles -contains $roleName)
                {
                    Write-Host "$roleName" -ForegroundColor Green
                }
                else
                {
                    Write-Host "$roleName - MISSING" -ForegroundColor Red
                }
            }
            Write-Host ""
            # Check Application Insights Permissions
            Write-Host "0.4 Checking Application Insights Permissions..." -ForegroundColor Yellow
            $appInsightsConnectionString = ($appSettings | Where-Object { $_.name -eq "APPLICATIONINSIGHTS_CONNECTION_STRING" }).value
            if ($appInsightsConnectionString)
            {
                # Extract instrumentation key or app ID from connection string
                # Supports both formats: InstrumentationKey and IngestionEndpoint-based connection strings
                $instrumentationKey = $null
                if ($appInsightsConnectionString -match "InstrumentationKey=([^;]+)")
                {
                    $instrumentationKey = $Matches[1]
                }
                elseif ($appInsightsConnectionString -match "Authorization=Bearer eyJ0eXAi" -or $appInsightsConnectionString -match "^https://")
                {
                    # IngestionEndpoint format - extract resource ID from endpoint URL
                    if ($appInsightsConnectionString -match "IngestionEndpoint=https://([^\.]+)")
                    {
                        $appInsightsName = $Matches[1]
                        Write-Host "  Application Insights Configured: Yes (IngestionEndpoint format)" -ForegroundColor Green
                        Write-Host "  Resource Name: $appInsightsName" -ForegroundColor Gray
                    }
                }

                if ($instrumentationKey)
                {
                    Write-Host "  Application Insights Configured: Yes" -ForegroundColor Green
                    Write-Host "  Instrumentation Key: $($instrumentationKey.Substring(0, 8))..." -ForegroundColor Gray
                    # Extract ApplicationId if present in connection string
                    $applicationId = $null
                    if ($appInsightsConnectionString -match "ApplicationId=([^;]+)")
                    {
                        $applicationId = $Matches[1]
                        Write-Host "  Application ID: $applicationId" -ForegroundColor Gray
                    }
                    # Try to find the Application Insights resource
                    # First try: look in the same resource group as the function app
                    $appInsights = $null
                    $appInsightsResources = az resource list `
                        --subscription $subscriptionId `
                        --resource-group $resourceGroupName `
                        --resource-type "Microsoft.Insights/components" `
                        -o json 2>&1
                    if ($LASTEXITCODE -eq 0 -and $appInsightsResources -and $appInsightsResources -ne "[]")
                    {
                        try
                        {
                            $componentsInRG = $appInsightsResources | ConvertFrom-Json
                            # Try to match by ApplicationId if available
                            if ($applicationId -and $componentsInRG.Count -gt 0)
                            {
                                foreach ($component in $componentsInRG)
                                {
                                    $detailsJson = az resource show --ids $component.id -o json 2>&1
                                    if ($LASTEXITCODE -eq 0)
                                    {
                                        $details = $detailsJson | ConvertFrom-Json
                                        if ($details.properties.AppId -eq $applicationId)
                                        {
                                            $appInsights = $details
                                            break
                                        }
                                    }
                                }
                            }
                            # If no match yet and only one component in RG, use it
                            if (-not $appInsights -and $componentsInRG.Count -eq 1)
                            {
                                $detailsJson = az resource show --ids $componentsInRG[0].id -o json 2>&1
                                if ($LASTEXITCODE -eq 0)
                                {
                                    $appInsights = $detailsJson | ConvertFrom-Json
                                }
                            }
                            if ($appInsights)
                            {
                                $appInsightsId = $appInsights.id
                                Write-Host "  Application Insights Name: $($appInsights.name)" -ForegroundColor Gray
                                Write-Host "  Resource Group: $resourceGroupName" -ForegroundColor Gray

                                # Check role assignments for Application Insights
                                $appInsightsRoles = Get-RoleAssignments -PrincipalId $principalId -Scope $appInsightsId -SubscriptionId $subscriptionId
                                $hasMonitoringPublisher = $appInsightsRoles | Where-Object { $_.roleDefinitionName -eq "Monitoring Metrics Publisher" }
                                if ($hasMonitoringPublisher)
                                {
                                    Write-Host "  Monitoring Metrics Publisher role: Assigned" -ForegroundColor Green
                                }
                                else
                                {
                                    Write-Host "  Monitoring Metrics Publisher role: NOT assigned" -ForegroundColor Yellow
                                    Write-Host "    Note: Function may still work with connection string auth" -ForegroundColor Gray
                                }
                            }
                            else
                            {
                                Write-Host "  Application Insights resource not found in resource group" -ForegroundColor Yellow
                                Write-Host "    Note: Function will use connection string for authentication" -ForegroundColor Gray
                            }
                        }
                        catch
                        {
                            Write-Host "  Could not retrieve Application Insights details" -ForegroundColor Yellow
                            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Gray
                            Write-Host "    Function will use connection string for authentication" -ForegroundColor Gray
                        }
                    }
                    else
                    {
                        Write-Host "  Application Insights not found in resource group: $resourceGroupName" -ForegroundColor Yellow
                        Write-Host "    Function will use connection string for authentication" -ForegroundColor Gray
                    }
                }
                elseif (-not $appInsightsConnectionString -match "IngestionEndpoint")
                {
                    Write-Host "  Application Insights connection string format not recognized" -ForegroundColor Yellow
                    Write-Host "  Supports InstrumentationKey or IngestionEndpoint formats" -ForegroundColor Gray
                }
            }
            else
            {
                Write-Host "  Application Insights: Not configured" -ForegroundColor Yellow
            }
            Write-Host ""
            # Check Microsoft Graph API Permissions
            Write-Host "0.5 Checking Microsoft Graph API Permissions..." -ForegroundColor Yellow
            $graphPermissions = Test-GraphApiPermissions -PrincipalId $principalId
            if ($graphPermissions.HasAccess)
            {
                Write-Host "Has required Microsoft Graph permissions" -ForegroundColor Green
                Write-Host "  Granted Permissions:" -ForegroundColor Gray
                foreach ($permission in $graphPermissions.Permissions)
                {
                    Write-Host "    - $permission" -ForegroundColor Gray
                }
            }
            else
            {
                Write-Host "Missing required Microsoft Graph permissions" -ForegroundColor Red
                if ($graphPermissions.MissingPermissions)
                {
                    Write-Host "  Missing Permissions:" -ForegroundColor Yellow
                    foreach ($permission in $graphPermissions.MissingPermissions)
                    {
                        Write-Host "    - $permission" -ForegroundColor Yellow
                    }
                }
                if ($graphPermissions.Error)
                {
                    Write-Host "  Error: $($graphPermissions.Error)" -ForegroundColor Red
                }
                Write-Host "  Run: .\tools\grant-graph-permissions.ps1" -ForegroundColor Cyan
            }
            Write-Host ""
            # Check EventGrid Permissions
            Write-Host "0.6 Checking EventGrid Permissions..." -ForegroundColor Yellow
            $eventGridScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.EventGrid/partnerTopics/$topicName"
            $eventGridRoles = Get-RoleAssignments -PrincipalId $principalId -Scope $eventGridScope -SubscriptionId $subscriptionId
            $hasEventGridReceiver = $eventGridRoles | Where-Object { $_.roleDefinitionName -like "*EventGrid*" -or $_.roleDefinitionName -like "*Event Grid*" }
            if ($hasEventGridReceiver)
            {
                Write-Host "Has EventGrid-related role assignments:" -ForegroundColor Green
                foreach ($role in $hasEventGridReceiver)
                {
                    Write-Host "    - $($role.roleDefinitionName)" -ForegroundColor Gray
                }
            }
            else
            {
                Write-Host "No specific EventGrid role assignments found" -ForegroundColor Yellow
                Write-Host "    Note: Function can still receive events via EventGrid trigger" -ForegroundColor Gray
            }
            Write-Host ""
        }
    }
}
elseif ($SkipPermissionChecks)
{
    Write-Host "Skipping permission checks (SkipPermissionChecks flag set)" -ForegroundColor Yellow
    Write-Host ""
}

# 2-5. Check diagnostics for each subscription
foreach ($graphSub in $graphSubs)
{
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "Examining Graph Subscription: $($graphSub.Id)" -ForegroundColor Yellow
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "2. Graph Subscription Details" -ForegroundColor Yellow
    Write-Host "  Resource: $($graphSub.Resource)" -ForegroundColor Gray
    Write-Host "  Notification URL: $($graphSub.NotificationUrl)" -ForegroundColor Gray
    Write-Host "  Lifecycle URL: $($graphSub.LifecycleNotificationUrl)" -ForegroundColor Gray
    Write-Host "  Change Types: $($graphSub.ChangeType)" -ForegroundColor Gray
    $expirationDateTime = [DateTime]::Parse($graphSub.ExpirationDateTime)
    $hoursUntilExpiration = ($expirationDateTime - (Get-Date)).TotalHours
    Write-Host "  Expires in: $([Math]::Round($hoursUntilExpiration, 1)) hours" -ForegroundColor Gray
    Write-Host ""

    # 3. Check EventGrid Partner Topic
    Write-Host "3. Checking EventGrid Partner Topic..." -ForegroundColor Yellow
    if (-not $rgExists)
    {
        Write-Host "SKIPPED: Cannot check partner topic - Resource Group not found" -ForegroundColor Yellow
        Write-Host "  See step 0 above for resource group validation details" -ForegroundColor Gray
        Write-Host ""
    }
    else
    {
        try
        {
            $partnerTopic = az eventgrid partner topic show `
                --name $topicName `
                --resource-group $resourceGroupName `
                --subscription $subscriptionId `
                -o json 2>&1
            if ($LASTEXITCODE -ne 0)
            {
                Write-Host "ERROR: Failed to retrieve partner topic" -ForegroundColor Red
                Write-Host "  Topic Name: $topicName" -ForegroundColor Gray
                Write-Host "  Resource Group: $resourceGroupName" -ForegroundColor Gray
                Write-Host "  Details: $partnerTopic" -ForegroundColor Gray
                Write-Host ""
                Write-Host "Please verify:" -ForegroundColor Yellow
                Write-Host "  1. Topic name is correct: $topicName" -ForegroundColor Gray
                Write-Host "  2. Topic exists in the resource group" -ForegroundColor Gray
                Write-Host "  3. List topics: az eventgrid partner topic list --resource-group $resourceGroupName" -ForegroundColor Cyan
            }
            else
            {
                $partnerTopic = $partnerTopic | ConvertFrom-Json
                Write-Host "  Provisioning State: $($partnerTopic.provisioningState)" -ForegroundColor Gray
                if ($partnerTopic.activationState -eq "Activated")
                {
                    Write-Host "Partner Topic is Activated" -ForegroundColor Green
                }
                else
                {
                    Write-Host "Partner Topic is NOT activated: $($partnerTopic.activationState)" -ForegroundColor Yellow
                }
            }
        }
        catch
        {
            Write-Host "ERROR: Exception checking partner topic" -ForegroundColor Red
            Write-Host "  Message: $($_.Exception.Message)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    # 4. Check Event Subscription
    Write-Host "4. Checking Event Subscription..." -ForegroundColor Yellow
    if (-not $rgExists)
    {
        Write-Host "SKIPPED: Cannot check event subscription - Resource Group not found" -ForegroundColor Yellow
        Write-Host "  See step 0 above for resource group validation details" -ForegroundColor Gray
        Write-Host ""
    }
    else
    {
        try
        {
            # First, list all event subscriptions on the topic to discover what's available
            $eventSubListResponse = az eventgrid partner topic event-subscription list `
                --resource-group $resourceGroupName `
                --partner-topic-name $topicName `
                --subscription $subscriptionId `
                -o json 2>&1
            if ($LASTEXITCODE -ne 0)
            {
                Write-Host "ERROR: Failed to list event subscriptions" -ForegroundColor Red
                Write-Host "  Topic Name: $topicName" -ForegroundColor Gray
                Write-Host "  Resource Group: $resourceGroupName" -ForegroundColor Gray
                Write-Host "  Details: $eventSubListResponse" -ForegroundColor Gray
                Write-Host ""
            }
            else
            {
                $eventSubList = $eventSubListResponse | ConvertFrom-Json
                if ($eventSubList -and $eventSubList.Count -gt 0)
                {
                    Write-Host "Found $($eventSubList.Count) event subscription(s) on this topic:" -ForegroundColor Cyan
                    # Try to find the best matching subscription
                    $targetEventSub = $null
                    # First try: exact function app name match
                    $targetEventSub = $eventSubList | Where-Object { $_.name -eq $functionAppName } | Select-Object -First 1
                    # Second try: name contains function app name
                    if (-not $targetEventSub)
                    {
                        $targetEventSub = $eventSubList | Where-Object { $_.name -like "*$functionAppName*" } | Select-Object -First 1
                    }
                    # Third try: just use the first one
                    if (-not $targetEventSub)
                    {
                        $targetEventSub = $eventSubList | Select-Object -First 1
                    }
                    # Display all subscriptions
                    foreach ($sub in $eventSubList)
                    {
                        $marker = if ($sub.name -eq $targetEventSub.name)
                        {
                            "→ "
                        }
                        else
                        {
                            "  "
                        }
                        Write-Host "$marker$($sub.name)" -ForegroundColor Gray
                    }
                    Write-Host ""
                    # Get details for the target subscription
                    if ($targetEventSub)
                    {
                        Write-Host "Examining event subscription: $($targetEventSub.name)" -ForegroundColor Cyan
                        # Get full details via REST API
                        $eventSubUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.EventGrid/partnerTopics/$topicName/eventSubscriptions/$($targetEventSub.name)?api-version=2022-06-15"
                        $eventSubResponse = az rest --method GET `
                            --uri $eventSubUri `
                            --subscription $subscriptionId `
                            -o json 2>&1
                        if ($LASTEXITCODE -eq 0)
                        {
                            $eventSub = $eventSubResponse | ConvertFrom-Json
                            if ($eventSub -and $eventSub.properties)
                            {
                                Write-Host "  Provisioning State: $($eventSub.properties.provisioningState)" -ForegroundColor Gray
                                Write-Host "  Destination Type: $($eventSub.properties.destination.endpointType)" -ForegroundColor Gray
                                if ($eventSub.properties.destination.properties.resourceId)
                                {
                                    Write-Host "  Destination: $($eventSub.properties.destination.properties.resourceId)" -ForegroundColor Gray
                                }
                                if ($eventSub.properties.filter -and $eventSub.properties.filter.advancedFilters -and $eventSub.properties.filter.advancedFilters.Count -gt 0)
                                {
                                    Write-Host "  Advanced Filters:" -ForegroundColor Gray
                                    foreach ($filter in $eventSub.properties.filter.advancedFilters)
                                    {
                                        Write-Host "    - $($filter.key) $($filter.operatorType): $($filter.values -join ', ')" -ForegroundColor Gray
                                    }
                                }
                                else
                                {
                                    Write-Host "  Advanced Filter: None configured" -ForegroundColor Gray
                                }
                            }
                        }
                    }
                }
                else
                {
                    Write-Host "No event subscriptions found on this topic" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "Please verify:" -ForegroundColor Yellow
                    Write-Host "  1. Topic name is correct: $topicName" -ForegroundColor Gray
                    Write-Host "  2. Event subscription has been created for this topic" -ForegroundColor Gray
                    Write-Host "  3. Check topic activation state in step 3 above" -ForegroundColor Gray
                }
            }
        }
        catch
        {
            Write-Host "ERROR: Exception checking event subscription" -ForegroundColor Red
            Write-Host "  Message: $($_.Exception.Message)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    # 5. Check EventGrid Metrics
    Write-Host "5. Checking EventGrid Metrics (last $eventTimeDays days)..." -ForegroundColor Yellow
    if (-not $rgExists)
    {
        Write-Host "SKIPPED: Cannot check metrics - Resource Group not found" -ForegroundColor Yellow
        Write-Host "  See step 0 above for resource group validation details" -ForegroundColor Gray
        Write-Host ""
    }
    else
    {
        try
        {
            $startTime = (Get-Date).AddDays(-$eventTimeDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $metricsResponse = az monitor metrics list `
                --resource "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.EventGrid/partnerTopics/$topicName" `
                --metric "PublishSuccessCount,MatchedEventCount,UnmatchedEventCount,DeliverySuccessCount,DeliveryAttemptFailCount,DroppedEventCount" `
                --start-time $startTime `
                --interval PT1H `
                --aggregation Total `
                -o json 2>&1
            if ($LASTEXITCODE -ne 0)
            {
                Write-Host "ERROR: Failed to retrieve metrics" -ForegroundColor Red
                Write-Host "  Partner Topic: $topicName" -ForegroundColor Gray
                Write-Host "  Resource Group: $resourceGroupName" -ForegroundColor Gray
                Write-Host "  Details: $metricsResponse" -ForegroundColor Gray
                Write-Host ""
                Write-Host "Please verify:" -ForegroundColor Yellow
                Write-Host "  1. Partner topic name is correct: $topicName" -ForegroundColor Gray
                Write-Host "  2. Metrics exist for this resource" -ForegroundColor Gray
            }
            else
            {
                $metrics = $metricsResponse | ConvertFrom-Json
                if ($metrics -and $metrics.value)
                {
                    foreach ($metric in $metrics.value)
                    {
                        $total = ($metric.timeseries.data | Measure-Object -Property total -Sum).Sum
                        $metricName = $metric.name.value
                        if ($total -gt 0)
                        {
                            Write-Host "  $metricName`: $total" -ForegroundColor Green
                        }
                        else
                        {
                            Write-Host "  $metricName`: $total" -ForegroundColor Gray
                        }
                    }
                }
                else
                {
                    Write-Host "  No metrics data available for this period" -ForegroundColor Gray
                    $metrics = @{ value = @() }
                }
            }
        }
        catch
        {
            Write-Host "ERROR: Exception checking metrics" -ForegroundColor Red
            Write-Host "  Message: $($_.Exception.Message)" -ForegroundColor Gray
            $metrics = @{ value = @() }
        }
        Write-Host ""
    }

    # 6. Diagnosis
    Write-Host "6. Diagnosis for this subscription" -ForegroundColor Cyan
    # First check: Validate integration between Graph subscription and EventGrid resources
    Write-Host ""
    Write-Host "6.1 Checking Resource Integration..." -ForegroundColor Yellow
    $integrationIssues = @()
    # Parse the NotificationUrl from Graph subscription to extract configuration
    if ($graphSub.NotificationUrl)
    {
        $notificationUrl = $graphSub.NotificationUrl
        # Extract parameters from the EventGrid URL format
        # Format: EventGrid:?azuresubscriptionid=XXX&resourcegroup=YYY&partnertopic=ZZZ&location=AAA
        $urlSubscriptionId = $null
        $urlResourceGroup = $null
        $urlPartnerTopic = $null
        $urlLocation = $null
        if ($notificationUrl -match "azuresubscriptionid=([^&]+)")
        {
            $urlSubscriptionId = $Matches[1]
        }
        if ($notificationUrl -match "resourcegroup=([^&]+)")
        {
            $urlResourceGroup = $Matches[1]
        }
        if ($notificationUrl -match "partnertopic=([^&]+)")
        {
            $urlPartnerTopic = $Matches[1]
        }
        if ($notificationUrl -match "location=([^&]+)")
        {
            $urlLocation = $Matches[1]
        }
        # Check if Graph subscription points to our resources
        if ($urlSubscriptionId -and $urlSubscriptionId -ne $subscriptionId)
        {
            $integrationIssues += "Graph subscription points to a different Azure subscription"
            Write-Host "  [ERROR] Subscription ID Mismatch" -ForegroundColor Red
            Write-Host "    Expected: $subscriptionId" -ForegroundColor Gray
            Write-Host "    In Graph: $urlSubscriptionId" -ForegroundColor Gray
        }
        else
        {
            Write-Host "  [OK] Subscription ID matches" -ForegroundColor Green
        }
        if ($urlResourceGroup -and $urlResourceGroup -ne $resourceGroupName)
        {
            $integrationIssues += "Graph subscription points to a different resource group"
            Write-Host "  [ERROR] Resource Group Mismatch" -ForegroundColor Red
            Write-Host "    Expected: $resourceGroupName" -ForegroundColor Gray
            Write-Host "    In Graph: $urlResourceGroup" -ForegroundColor Gray
        }
        else
        {
            Write-Host "  [OK] Resource Group matches" -ForegroundColor Green
        }
        if ($urlPartnerTopic -and $urlPartnerTopic -ne $topicName)
        {
            $integrationIssues += "Graph subscription points to a different partner topic"
            Write-Host "  [ERROR] Partner Topic Mismatch" -ForegroundColor Red
            Write-Host "    Expected: $topicName" -ForegroundColor Gray
            Write-Host "    In Graph: $urlPartnerTopic" -ForegroundColor Gray
        }
        else
        {
            Write-Host "  [OK] Partner Topic matches" -ForegroundColor Green
        }
    }

    # Check if event subscription points to our function
    if ($targetEventSub -and $targetEventSub.properties.destination)
    {
        $destination = $targetEventSub.properties.destination
        if ($destination.properties.resourceId)
        {
            $destResourceId = $destination.properties.resourceId
            # Expected format: /subscriptions/XXX/resourceGroups/YYY/providers/Microsoft.Web/sites/ZZZ/functions/AAA
            $expectedFunctionPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$functionAppName"
            if ($destResourceId -like "$expectedFunctionPath*")
            {
                Write-Host "  [OK] Event subscription points to function app: $functionAppName" -ForegroundColor Green
                # Extract the function name from the destination
                if ($destResourceId -match "/functions/([^/]+)$")
                {
                    $actualFunctionName = $Matches[1]
                    Write-Host "    Function: $actualFunctionName" -ForegroundColor Gray
                }
            }
            else
            {
                $integrationIssues += "Event subscription points to a different function app"
                Write-Host "  [ERROR] Event subscription destination mismatch" -ForegroundColor Red
                Write-Host "    Expected function app: $functionAppName" -ForegroundColor Gray
                Write-Host "    Actual destination: $destResourceId" -ForegroundColor Gray
            }
        }
    }

    if ($integrationIssues.Count -gt 0)
    {
        Write-Host ""
        Write-Host "INTEGRATION ISSUES DETECTED:" -ForegroundColor Red
        foreach ($issue in $integrationIssues)
        {
            Write-Host "  - $issue" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "Action Required:" -ForegroundColor Yellow
        Write-Host "  The Graph subscription and EventGrid resources are not properly integrated." -ForegroundColor Gray
        Write-Host "  You may need to recreate the Graph subscription with correct parameters." -ForegroundColor Gray
        Write-Host "  Use: .\tools\create-api-subscription-topic.ps1" -ForegroundColor Cyan
    }
    else
    {
        Write-Host "  [OK] All resources are properly integrated" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "6.2 Checking Event Delivery..." -ForegroundColor Yellow

    if (-not $rgExists)
    {
        Write-Host "Cannot provide diagnosis - Resource Group configuration issue" -ForegroundColor Yellow
        Write-Host "Resolve the resource group issue in step 0 to enable full diagnostics" -ForegroundColor Gray
    }
    elseif ($null -eq $metrics -or $metrics.value.Count -eq 0)
    {
        Write-Host "Cannot provide diagnosis - Metrics data unavailable" -ForegroundColor Yellow
        Write-Host "This may indicate the resource group or partner topic does not exist" -ForegroundColor Gray
    }
    else
    {
        $publishSuccessMetric = $metrics.value | Where-Object { $_.name.value -eq "PublishSuccessCount" }
        $unmatchedEventMetric = $metrics.value | Where-Object { $_.name.value -eq "UnmatchedEventCount" }
        $deliveryFailMetric = $metrics.value | Where-Object { $_.name.value -eq "DeliveryAttemptFailCount" }

        $publishSuccessTotal = if ($publishSuccessMetric -and $publishSuccessMetric.timeseries.data)
        {
            ($publishSuccessMetric.timeseries.data | Measure-Object -Property total -Sum).Sum
        }
        else
        {
            0
        }
        $unmatchedEventTotal = if ($unmatchedEventMetric -and $unmatchedEventMetric.timeseries.data)
        {
            ($unmatchedEventMetric.timeseries.data | Measure-Object -Property total -Sum).Sum
        }
        else
        {
            0
        }
        $deliveryFailTotal = if ($deliveryFailMetric -and $deliveryFailMetric.timeseries.data)
        {
            ($deliveryFailMetric.timeseries.data | Measure-Object -Property total -Sum).Sum
        }
        else
        {
            0
        }

        if ($publishSuccessTotal -eq 0)
        {
            Write-Host "NO EVENTS PUBLISHED" -ForegroundColor Red
            Write-Host "   Microsoft Graph is not sending events to EventGrid." -ForegroundColor Yellow
            Write-Host "   Possible causes:" -ForegroundColor Yellow
            Write-Host "   - No group changes have occurred" -ForegroundColor Yellow
            Write-Host "   - Graph subscription may need to be recreated" -ForegroundColor Yellow
            Write-Host "   - NotificationUrl mismatch between Graph and EventGrid" -ForegroundColor Yellow
        }
        elseif ($unmatchedEventTotal -gt 0)
        {
            Write-Host "EVENTS PUBLISHED BUT NOT MATCHED" -ForegroundColor Yellow
            Write-Host "   Events are arriving but the filter is rejecting them." -ForegroundColor Yellow
            Write-Host "   Check the advanced filter configuration in step 4 above" -ForegroundColor Yellow
        }
        elseif ($deliveryFailTotal -gt 0)
        {
            Write-Host "DELIVERY FAILURES" -ForegroundColor Yellow
            Write-Host "   Events are matched but delivery to function is failing." -ForegroundColor Yellow
        }
        else
        {
            Write-Host "Configuration appears correct" -ForegroundColor Green
            Write-Host "   Waiting for group changes to trigger events..." -ForegroundColor Gray
        }
    }
    Write-Host ""
}

Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Examined $($graphSubs.Count) subscription(s)" -ForegroundColor Green