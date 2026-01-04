<#
.SYNOPSIS
    Renews an existing Microsoft Graph change notification subscription.

.DESCRIPTION
    This script reads the subscription information from subscription-info.json and renews it
    with a new expiration date. Should be run before the subscription expires (ideally 1 day before).

.PARAMETER SubscriptionId
    The ID of the subscription to renew. If not provided, reads from subscription-info.json.

.EXAMPLE
    .\renew-subscription.ps1
    Renews the subscription using information from subscription-info.json

.EXAMPLE
    .\renew-subscription.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012"
    Renews a specific subscription by ID
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId
)

Import-Module Microsoft.Graph.ChangeNotifications

# If no SubscriptionId provided, try to read from saved file
if (-not $SubscriptionId) {
    $infoFile = "subscription-info.json"
    if (Test-Path $infoFile) {
        Write-Host "Reading subscription info from $infoFile..." -ForegroundColor Cyan
        $subscriptionInfo = Get-Content $infoFile | ConvertFrom-Json
        $SubscriptionId = $subscriptionInfo.SubscriptionId
    }
    else {
        Write-Host "Error: No subscription ID provided and $infoFile not found" -ForegroundColor Red
        Write-Host "Usage: .\renew-subscription.ps1 -SubscriptionId <id>" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "Renewing subscription: $SubscriptionId" -ForegroundColor Cyan

# Set new expiration to maximum allowed (4230 minutes = ~3 days)
$expirationMinutes = 4230
$newExpirationDate = (Get-Date).AddMinutes($expirationMinutes)

Write-Host "  New expiration: $newExpirationDate ($expirationMinutes minutes)" -ForegroundColor Gray

try {
    # Get current subscription details
    Write-Host "`nFetching current subscription details..." -ForegroundColor Cyan
    $currentSubscription = Get-MgSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop

    Write-Host "  Current expiration: $($currentSubscription.ExpirationDateTime)" -ForegroundColor Gray
    Write-Host "  Resource: $($currentSubscription.Resource)" -ForegroundColor Gray

    # Update the subscription with new expiration
    $updateParams = @{
        ExpirationDateTime = $newExpirationDate
    }

    Write-Host "`nUpdating subscription..." -ForegroundColor Cyan
    $updatedSubscription = Update-MgSubscription -SubscriptionId $SubscriptionId -BodyParameter $updateParams

    Write-Host "`nSubscription renewed successfully!" -ForegroundColor Green
    Write-Host "  Subscription ID: $($updatedSubscription.Id)" -ForegroundColor Yellow
    Write-Host "  New expiration: $($updatedSubscription.ExpirationDateTime)" -ForegroundColor Yellow

    # Update saved subscription info
    if (Test-Path "subscription-info.json") {
        $subscriptionInfo = Get-Content "subscription-info.json" | ConvertFrom-Json
        $subscriptionInfo.ExpirationDateTime = $updatedSubscription.ExpirationDateTime
        $subscriptionInfo.LastRenewed = (Get-Date).ToString("o")
        $subscriptionInfo | ConvertTo-Json -Depth 10 | Set-Content -Path "subscription-info.json"
        Write-Host "`nUpdated subscription-info.json" -ForegroundColor Green
    }

    # Calculate next renewal time
    $nextRenewal = $newExpirationDate.AddDays(-1)
    Write-Host "`nNext renewal should occur before: $nextRenewal" -ForegroundColor Yellow

    return $updatedSubscription
}
catch {
    Write-Host "`nError renewing subscription:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.Exception.Message -like "*ResourceNotFound*" -or $_.Exception.Message -like "*does not exist*") {
        Write-Host "`nThe subscription may have expired or been deleted." -ForegroundColor Yellow
        Write-Host "Run .\create-api-subscription-topic.ps1 to create a new subscription." -ForegroundColor Yellow
    }

    throw
}
