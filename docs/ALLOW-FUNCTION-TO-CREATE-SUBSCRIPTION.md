# Allow Function App to Create Its Own Subscription

Add this code to `RenewSubscription/run.ps1` after the `Connect-MgGraph` call:

```powershell
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
        changeType = "updated,deleted,created"
        notificationUrl = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location"
        lifecycleNotificationUrl = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location"
        resource = "groups"
        expirationDateTime = $newExpiration
        clientState = $clientState
    }

    try
    {
        $newSubscription = New-MgSubscription -BodyParameter $createParams
        Write-Host "✅ Created new subscription: $($newSubscription.Id)" -ForegroundColor Green
        Write-Host "   Expires: $($newSubscription.ExpirationDateTime)" -ForegroundColor Green

        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] SUCCESS: Created new subscription $($newSubscription.Id)"
        $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Expiration: $($newSubscription.ExpirationDateTime)"

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
```

## Benefits
- Function App becomes self-sufficient
- No local subscription creation needed
- Automatic subscription creation on first run
- Subscription owned by managed identity
- Works in all environments

## Required Environment Variables
Add these to Function App settings if not already present:
- `AZURE_SUBSCRIPTION_ID` - Already set
- `RESOURCE_GROUP_NAME` - Optional, defaults to "groupchangefunction"
- `PARTNER_TOPIC_NAME` - Optional, defaults to "default"
- `AZURE_REGION` - Optional, defaults to "centralus"
