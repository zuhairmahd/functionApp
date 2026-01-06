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

# Import required modules
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.ChangeNotifications

# Queue storage diagnostic logging
$diagnosticLog = @()
$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === RenewSubscription Function Started ==="

Write-Host "================================================"
Write-Host "Microsoft Graph Subscription Renewal Function"
Write-Host "================================================"
Write-Host "Execution time: $((Get-Date).ToString('o'))"

$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Execution started"
$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Checking GRAPH_SUBSCRIPTION_ID environment variable"

# Get client ID from environment variable or App Configuration
$managedIdentityClientId = $env:AZURE_CLIENT_ID
$subscriptionRenewalPeriodHours = if ($env:SUBSCRIPTION_RENEWAL_PERIOD_HOURS)
{
    [int]$env:SUBSCRIPTION_RENEWAL_PERIOD_HOURS
}
else
{
    24
}

# Try to find subscription by querying all subscriptions for this resource
try
{
    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Microsoft Graph using Managed Identity"
    Connect-MgGraph -Identity -ClientId $managedIdentityClientId -NoWelcome
    Write-Host "Connected to Microsoft Graph"
    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Successfully connected to Microsoft Graph"

    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Querying all subscriptions"
    $allSubscriptions = Get-MgSubscription -All
    Write-Host "Got $($allSubscriptions.Count) total subscriptions  "
    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Found $($allSubscriptions.Count) total subscription(s)"

    # Filter for subscriptions that use EventGrid and match our resource
    $relevantSubscriptions = $allSubscriptions | Where-Object {
        $_.NotificationUrl -like "*EventGrid*" -and
        $_.Resource -eq "groups"
    }
    Write-Host "Filtering for subscriptions with resource 'groups' and EventGrid notification URL"
    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Filtering for EventGrid subscriptions with 'groups' resource"
    if ($relevantSubscriptions.Count -eq 0)
    {
        Write-Host "No subscriptions found - creating new one..." -ForegroundColor Yellow
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] No subscriptions found - creating new subscription"

        $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
        $resourceGroup = $env:RESOURCE_GROUP_NAME ?? "groupchangefunction"
        $partnerTopic = $env:PARTNER_TOPIC_NAME ?? "default"
        $location = $env:AZURE_REGION ?? "centralus"

        $newExpiration = (Get-Date).AddMinutes(4230)
        $clientState = [Guid]::NewGuid().ToString()

        $createParams = @{
            changeType               = "updated,deleted,created"
            notificationUrl          = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location"
            lifecycleNotificationUrl = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location"
            resource                 = "groups"
            expirationDateTime       = $newExpiration
            clientState              = $clientState
        }

        try
        {
            $newSubscription = New-MgSubscription -BodyParameter $createParams
            Write-Host "✅ Created new subscription: $($newSubscription.Id)" -ForegroundColor Green
            Write-Host "   Expires: $($newSubscription.ExpirationDateTime)" -ForegroundColor Green

            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] SUCCESS: Created new subscription $($newSubscription.Id)"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Expiration: $($newSubscription.ExpirationDateTime)"

            # IMPORTANT: Subscription ID changes each time a new subscription is created
            # Option 1: Set GRAPH_SUBSCRIPTION_ID env var manually in Azure Portal to optimize future runs
            # Option 2: Leave it unset - function will query all subscriptions (works fine, just slower)
            Write-Host "⚠️  IMPORTANT: New subscription ID generated" -ForegroundColor Yellow
            Write-Host "   To optimize future runs, set GRAPH_SUBSCRIPTION_ID in Function App settings:" -ForegroundColor Yellow
            Write-Host "   Value: $($newSubscription.Id)" -ForegroundColor White

            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] IMPORTANT: Set GRAPH_SUBSCRIPTION_ID=$($newSubscription.Id) in Function App settings"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Without this setting, function will query all subscriptions on each run"

            # Continue processing with this new subscription
            $relevantSubscriptions = @($newSubscription)
        }
        catch
        {
            Write-Error "Failed to create subscription: $($_.Exception.Message)"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: Failed to create subscription - $($_.Exception.Message)"
            Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")
            throw
        }
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

        # Renew if expiring within subscription renewal period hours
        if ($hoursUntilExpiration -lt $subscriptionRenewalPeriodHours)
        {
            Write-Host "  ⚠️  Subscription expires soon! Renewing..." -ForegroundColor Yellow
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   WARNING: Subscription expires within $subscriptionRenewalPeriodHours hours - initiating renewal"
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
                $errorMsg = $_.Exception.Message
                Write-Error "  ❌ Failed to renew subscription: $errorMsg"
                $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   ERROR: Failed to renew subscription - $errorMsg"

                # If subscription is expired, invalid, or doesn't belong to this app
                if ($errorMsg -like "*ResourceNotFound*" -or $errorMsg -like "*expired*" -or $errorMsg -like "*does not belong to application*")
                {
                    Write-Warning "  The subscription may have expired or was created by a different application."
                    Write-Warning "  Run create-api-subscription-topic.ps1 to create a new subscription."
                    Write-Warning "  For Function App: Subscription must be created using the managed identity."
                    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   ERROR: Subscription expired or created by different app - manual recreation required"
                    $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]   HINT: Subscription must be owned by managed identity: $managedIdentityClientId"
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

Write-Host "`n================================================"
Write-Host "Renewal check completed at $((Get-Date).ToString('o'))"
Write-Host "================================================"

# Push all diagnostic logs to queue storage
$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === RenewSubscription Function Completed ==="
Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")

Disconnect-MgGraph
Write-Host "`nDisconnected from Microsoft Graph"
