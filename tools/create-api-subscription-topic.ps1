<#
.SYNOPSIS
    Creates a Microsoft Graph change notification subscription for group changes.

.DESCRIPTION
    This script creates a subscription to receive notifications when groups are created, updated, or deleted.
    The subscription is configured to send events to Azure EventGrid Partner Topic.

    Maximum expiration time for Graph subscriptions is 4230 minutes (~3 days).
    A renewal function should be deployed to keep the subscription active.

.NOTES
    - Requires Microsoft.Graph.ChangeNotifications module
    - Requires appropriate Graph API permissions (Group.Read.All)
    - The subscription ID is saved to subscription-info.json for renewal purposes
#>
[CmdletBinding()]
param()

Import-Module Microsoft.Graph.ChangeNotifications

# Azure and EventGrid configuration
$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"
$resourceGroup = "groupchangefunction"
$partnerTopic = "default"
$location = "centralus"

# Set expiration to maximum allowed (4230 minutes = ~3 days)
$expirationMinutes = 4230
$expirationDate = (Get-Date).AddMinutes($expirationMinutes)

Write-Host "Creating Microsoft Graph subscription..." -ForegroundColor Cyan
Write-Host "  Resource: groups" -ForegroundColor Gray
Write-Host "  Change types: created, updated, deleted" -ForegroundColor Gray
Write-Host "  Expiration: $expirationDate ($expirationMinutes minutes)" -ForegroundColor Gray

$params = @{
    changeType               = "updated,deleted,created"
    notificationUrl          = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location"
    lifecycleNotificationUrl = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location"
    resource                 = "groups"
    expirationDateTime       = $expirationDate
    clientState              = "$(New-Guid)"
}

try {
    $subscription = New-MgSubscription -BodyParameter $params

    Write-Host "`nSubscription created successfully!" -ForegroundColor Green
    Write-Host "  Subscription ID: $($subscription.Id)" -ForegroundColor Yellow
    Write-Host "  Expires at: $($subscription.ExpirationDateTime)" -ForegroundColor Yellow

    # Save subscription information for renewal
    $subscriptionInfo = @{
        SubscriptionId = $subscription.Id
        Resource = $subscription.Resource
        ChangeType = $subscription.ChangeType
        ExpirationDateTime = $subscription.ExpirationDateTime
        CreatedDateTime = (Get-Date).ToString("o")
        NotificationUrl = $params.notificationUrl
        LifecycleNotificationUrl = $params.lifecycleNotificationUrl
        ClientState = $params.clientState
    }

    $subscriptionInfo | ConvertTo-Json -Depth 10 | Set-Content -Path "subscription-info.json"
    Write-Host "`nSubscription info saved to subscription-info.json" -ForegroundColor Green

    # Calculate renewal time (renew 1 day before expiration)
    $renewalTime = $expirationDate.AddDays(-1)
    Write-Host "`nIMPORTANT: Schedule renewal before $renewalTime" -ForegroundColor Yellow
    Write-Host "Run .\renew-subscription.ps1 or deploy the RenewSubscription function" -ForegroundColor Yellow

    return $subscription
}
catch {
    Write-Host "`nError creating subscription:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nMake sure you have:" -ForegroundColor Yellow
    Write-Host "  1. Connected to Microsoft Graph (Connect-MgGraph)" -ForegroundColor Yellow
    Write-Host "  2. Appropriate permissions (Group.Read.All)" -ForegroundColor Yellow
    Write-Host "  3. Partner topic is activated in Azure" -ForegroundColor Yellow
    throw
}