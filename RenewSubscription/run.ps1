<#
.SYNOPSIS
    Azure Function to automatically renew Microsoft Graph change notification subscriptions.

.DESCRIPTION
    This timer-triggered function runs every 12 hours to check and renew Graph API subscriptions
    before they expire. It reads subscription information from Azure App Configuration or
    environment variables and renews subscriptions that are close to expiring.

.NOTES
    - Runs on a timer trigger (every 12 hours by default)
    - Renews subscriptions that expire within 24 hours
    - Requires Microsoft.Graph.ChangeNotifications module
    - Requires appropriate Graph API permissions
#>
[CmdletBinding()]
param($Timer)

#region log received event
$events = if ($Timer -is [System.Array])
{
    $Timer
}
else
{
    @($Timer)
}
$humanReadable = foreach ($evt in $events)
{
    $lines = @()
    $lines += "Id: $($evt.id)"
    $evtType = $evt.eventType
    if (-not $evtType)
    {
        $evtType = $evt.type
    }
    $lines += "EventType: $evtType"
    $lines += "Subject: $($evt.subject)"
    $evtTime = $evt.eventTime
    if (-not $evtTime)
    {
        $evtTime = $evt.time
    }
    $lines += "EventTime: $evtTime"
    $lines += "DataVersion: $($evt.dataVersion)"
    $lines += "MetadataVersion: $($evt.metadataVersion)"
    $lines += "Data:"
    $lines += ($evt.data | ConvertTo-Json -Depth 8 -Compress)
    $lines -join "`n"
}
# Still log to console for quick local verification
($humanReadable -join "`n`n") | Write-Host
$logPayload = @()
$logPayload += ""
$logPayload += "=== Event Snapshot ==="
$logPayload += ($humanReadable -join "`n`n")
Push-OutputBinding -Name log -Value ($logPayload -join "`n")
Write-Verbose "Received event: $($Timer      |Out-String)"
Write-Host "received event: $($Timer | Out-String)" -ForegroundColor Cyan
#endregion log received event

$managedIdentityClientId = "0ed597a6-5cca-4c6f-b51e-10510010e936"

# Import required modules
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.ChangeNotifications
$ErrorActionPreference = "Stop"

# Queue storage diagnostic logging
$diagnosticLog = @()
$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === RenewSubscription Function Started ==="

Write-Host "================================================"
Write-Host "Microsoft Graph Subscription Renewal Function"
Write-Host "================================================"
Write-Host "Execution time: $((Get-Date).ToString('o'))"

$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Execution started"
$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Checking GRAPH_SUBSCRIPTION_ID environment variable"

# Get subscription ID from environment variable or App Configuration
$graphSubscriptionId = $env:GRAPH_SUBSCRIPTION_ID

if (-not $graphSubscriptionId)
{
    Write-Warning "No GRAPH_SUBSCRIPTION_ID found in environment variables"
    Write-Host "Checking for subscription info in local context..."

    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] No GRAPH_SUBSCRIPTION_ID in environment, querying all subscriptions"

    # Try to find subscription by querying all subscriptions for this resource
    try
    {
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Microsoft Graph using Managed Identity"
        Connect-MgGraph -Identity -ClientId $managedIdentityClientId -NoWelcome
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Successfully connected to Microsoft Graph"

        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Querying all subscriptions"
        $allSubscriptions = Get-MgSubscription -All
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Found $($allSubscriptions.Count) total subscription(s)"

        # Filter for subscriptions that use EventGrid and match our resource
        $relevantSubscriptions = $allSubscriptions | Where-Object {
            $_.NotificationUrl -like "*EventGrid*" -and
            $_.Resource -eq "groups"
        }

        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Filtering for EventGrid subscriptions with 'groups' resource"

        if ($relevantSubscriptions.Count -eq 0)
        {
            Write-Warning "No active Graph subscriptions found for groups resource with EventGrid"
            Write-Host "You may need to run create-api-subscription-topic.ps1 to create a subscription"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: No relevant subscriptions found"
            Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")
            return
        }

        Write-Host "Found $($relevantSubscriptions.Count) relevant subscription(s)"
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Found $($relevantSubscriptions.Count) relevant subscription(s)"

        foreach ($sub in $relevantSubscriptions)
        {
            $graphSubscriptionId = $sub.Id
            Write-Host "`nProcessing subscription: $graphSubscriptionId"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Processing subscription: $graphSubscriptionId"

            $expirationDateTime = [DateTime]::Parse($sub.ExpirationDateTime)
            $hoursUntilExpiration = ($expirationDateTime - (Get-Date)).TotalHours

            Write-Host "  Resource: $($sub.Resource)"
            Write-Host "  Expiration: $expirationDateTime"
            Write-Host "  Hours until expiration: $([Math]::Round($hoursUntilExpiration, 2))"

            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   Resource: $($sub.Resource)"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   Expiration: $expirationDateTime"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   Hours until expiration: $([Math]::Round($hoursUntilExpiration, 2))"

            # Renew if expiring within 24 hours
            if ($hoursUntilExpiration -lt 24)
            {
                Write-Host "  ⚠️  Subscription expires soon! Renewing..." -ForegroundColor Yellow
                $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   WARNING: Subscription expires within 24 hours - initiating renewal"

                # Set new expiration to maximum (4230 minutes)
                $newExpiration = (Get-Date).AddMinutes(4230)
                $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   Attempting renewal with new expiration: $($newExpiration.ToString('o'))"

                $updateParams = @{
                    ExpirationDateTime = $newExpiration
                }

                try
                {
                    $updated = Update-MgSubscription -SubscriptionId $graphSubscriptionId -BodyParameter $updateParams
                    Write-Host "  ✅ Subscription renewed successfully!" -ForegroundColor Green
                    Write-Host "  New expiration: $($updated.ExpirationDateTime)" -ForegroundColor Green
                    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   SUCCESS: Subscription renewed successfully"
                    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   New expiration: $($updated.ExpirationDateTime)"
                }
                catch
                {
                    Write-Error "  ❌ Failed to renew subscription: $($_.Exception.Message)"
                    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   ERROR: Failed to renew subscription - $($_.Exception.Message)"

                    # If subscription is expired or invalid, log for manual intervention
                    if ($_.Exception.Message -like "*ResourceNotFound*" -or $_.Exception.Message -like "*expired*")
                    {
                        Write-Warning "  The subscription may have expired. Manual recreation required."
                        Write-Warning "  Run create-api-subscription-topic.ps1 to create a new subscription."
                        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   ERROR: Subscription may be expired or deleted - manual recreation required"
                    }
                }
            }
            else
            {
                Write-Host "  ✅ Subscription is still valid (expires in $([Math]::Round($hoursUntilExpiration, 1)) hours)" -ForegroundColor Green
                $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   INFO: Subscription is still valid (expires in $([Math]::Round($hoursUntilExpiration, 1)) hours) - no renewal needed"
            }
        }

        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Completed processing all subscriptions"
    }
    catch
    {
        Write-Error "Failed to connect to Microsoft Graph or query subscriptions: $($_.Exception.Message)"
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: Failed to connect to Microsoft Graph - $($_.Exception.Message)"
        Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")
        throw
    }
}
else
{
    Write-Host "Processing subscription ID from environment: $graphSubscriptionId"
    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Using GRAPH_SUBSCRIPTION_ID from environment: $graphSubscriptionId"

    try
    {
        # Connect using User-Assigned Managed Identity
        # The Function App uses: groupchangefunction-identities-9bef22
        # Client ID: 0ed597a6-5cca-4c6f-b51e-10510010e936
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Microsoft Graph using Managed Identity"
        Connect-MgGraph -Identity -ClientId $managedIdentityClientId -NoWelcome
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Successfully connected to Microsoft Graph"

        # Get current subscription
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Retrieving subscription details"
        $subscription = Get-MgSubscription -SubscriptionId $graphSubscriptionId

        $expirationDateTime = [DateTime]::Parse($subscription.ExpirationDateTime)
        $hoursUntilExpiration = ($expirationDateTime - (Get-Date)).TotalHours

        Write-Host "Current subscription details:"
        Write-Host "  Resource: $($subscription.Resource)"
        Write-Host "  Expiration: $expirationDateTime"
        Write-Host "  Hours until expiration: $([Math]::Round($hoursUntilExpiration, 2))"

        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Subscription details retrieved"
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   Resource: $($subscription.Resource)"
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   Expiration: $expirationDateTime"
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   Hours until expiration: $([Math]::Round($hoursUntilExpiration, 2))"

        # Renew if expiring within 24 hours
        if ($hoursUntilExpiration -lt 24)
        {
            Write-Host "Subscription expires soon! Renewing..." -ForegroundColor Yellow
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: Subscription expires within 24 hours - initiating renewal"

            $newExpiration = (Get-Date).AddMinutes(4230)
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempting renewal with new expiration: $($newExpiration.ToString('o'))"

            $updateParams = @{
                ExpirationDateTime = $newExpiration
            }

            $updated = Update-MgSubscription -SubscriptionId $graphSubscriptionId -BodyParameter $updateParams

            Write-Host "✅ Subscription renewed successfully!" -ForegroundColor Green
            Write-Host "New expiration: $($updated.ExpirationDateTime)" -ForegroundColor Green
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] SUCCESS: Subscription renewed successfully"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] New expiration: $($updated.ExpirationDateTime)"
        }
        else
        {
            Write-Host "✅ Subscription is still valid" -ForegroundColor Green
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] INFO: Subscription is still valid (expires in $([Math]::Round($hoursUntilExpiration, 1)) hours) - no renewal needed"
        }
    }
    catch
    {
        Write-Error "Failed to renew subscription: $($_.Exception.Message)"
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: Failed to process subscription - $($_.Exception.Message)"
        Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")
        throw
    }
}

Write-Host "`n================================================"
Write-Host "Renewal check completed at $((Get-Date).ToString('o'))"
Write-Host "================================================"

# Push all diagnostic logs to queue storage
$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === RenewSubscription Function Completed ==="
Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")
