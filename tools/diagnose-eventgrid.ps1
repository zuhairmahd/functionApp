<#
.SYNOPSIS
    Diagnoses EventGrid event delivery issues for Microsoft Graph subscriptions.

.DESCRIPTION
    This script performs comprehensive diagnostics on Microsoft Graph change notification subscriptions
    configured to send events to Azure EventGrid. It examines:
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
    Used to locate and validate the event subscription configuration.
    Default: "FunctionApp"

.PARAMETER eventTimeDays
    Number of days of historical metrics to retrieve and analyze (default: 1 day).
    Useful for checking metrics over longer periods when diagnosing intermittent issues.
    Default: 1

.EXAMPLE
    .\diagnose-eventgrid.ps1
    Performs auto-discovery of EventGrid subscriptions and diagnoses all found subscriptions
    using default parameter values.

.EXAMPLE
    .\diagnose-eventgrid.ps1 -graphSubscriptionId "69b82601-c3c8-446f-a72c-2384784cd404"
    Diagnoses a specific Graph subscription and checks its EventGrid configuration.

.EXAMPLE
    .\diagnose-eventgrid.ps1 -graphSubscriptionId "69b82601-c3c8-446f-a72c-2384784cd404" `
        -resourceGroupName "myResourceGroup" -topicName "myTopic" -functionAppName "myFunction"
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

    Related Scripts:
    - create-api-subscription-topic.ps1 - Creates new Graph subscription and EventGrid topic
    - grant-graph-permissions.ps1 - Grants Graph API permissions to managed identity
    - check-subscription.ps1 - Lists all Graph subscriptions
    - renew-subscription.ps1 - Manually renews a Graph subscription

.LINK
    https://learn.microsoft.com/en-us/graph/api/subscription-post-subscriptions
    https://learn.microsoft.com/en-us/azure/event-grid/concepts
#>
[CmdletBinding()]
param(
    [string]$graphSubscriptionId = "",
    [string]$topicName = "groupchangefunctiontopic",
    [string]$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b",
    [string]$functionAppName = "FunctionApp",
    [string]$resourceGroupName = "groupchangefunction",
    [int]$eventTimeDays = 1
)

Write-Host "=== EventGrid Diagnostics ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Using the following parameters:" -ForegroundColor Cyan
Write-Host " Graph Subscription ID: $(if ([string]::IsNullOrEmpty($graphSubscriptionId)) { '[AUTO-DETECT]' } else { $graphSubscriptionId })" -ForegroundColor Gray
Write-Host " EventGrid Topic Name: $topicName" -ForegroundColor Gray
Write-Host " Resource Group Name: $resourceGroupName" -ForegroundColor Gray
Write-Host " Function App Name: $functionAppName" -ForegroundColor Gray
Write-Host " Subscription ID: $subscriptionId" -ForegroundColor Gray
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
            --name $ResourceGroupName `
            --query value -o tsv

        return $result -eq "true"
    }
    catch
    {
        return $false
    }
}

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
    Write-Host "No subscription ID provided. Searching for EventGrid-based subscriptions..." -ForegroundColor Cyan
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
                --query "{activationState:properties.activationState, provisioningState:properties.provisioningState}" `
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
            $eventSubUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.EventGrid/partnerTopics/$topicName/eventSubscriptions/$functionAppName`?api-version=2022-06-15"

            $eventSubResponse = az rest --method GET `
                --uri $eventSubUri `
                --subscription $subscriptionId `
                -o json 2>&1

            if ($LASTEXITCODE -ne 0)
            {
                Write-Host "ERROR: Failed to retrieve event subscription" -ForegroundColor Red
                Write-Host "  Function App Name: $functionAppName" -ForegroundColor Gray
                Write-Host "  Topic Name: $topicName" -ForegroundColor Gray
                Write-Host "  Resource Group: $resourceGroupName" -ForegroundColor Gray
                Write-Host "  Details: $eventSubResponse" -ForegroundColor Gray
                Write-Host ""
                Write-Host "Please verify:" -ForegroundColor Yellow
                Write-Host "  1. Function App name is correct: $functionAppName" -ForegroundColor Gray
                Write-Host "  2. Event subscription exists for this function" -ForegroundColor Gray
                Write-Host "  3. List event subscriptions: az eventgrid partner topic event-subscription list --resource-group $resourceGroupName --topic-name $topicName" -ForegroundColor Cyan
            }
            else
            {
                $eventSub = $eventSubResponse | ConvertFrom-Json

                if ($eventSub -and $eventSub.properties)
                {
                    Write-Host "  Provisioning State: $($eventSub.properties.provisioningState)" -ForegroundColor Gray

                    if ($eventSub.properties.filter -and $eventSub.properties.filter.advancedFilters -and $eventSub.properties.filter.advancedFilters.Count -gt 0)
                    {
                        Write-Host "  Advanced Filter: $($eventSub.properties.filter.advancedFilters[0].key) $($eventSub.properties.filter.advancedFilters[0].operatorType)" -ForegroundColor Gray
                    }
                    else
                    {
                        Write-Host "  Advanced Filter: None configured" -ForegroundColor Gray
                    }
                }
                else
                {
                    Write-Host "ERROR: Event subscription response is empty or malformed" -ForegroundColor Red
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
