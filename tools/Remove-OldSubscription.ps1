<#
.SYNOPSIS
    Removes the old Microsoft Graph subscription that was created by a different application.

.DESCRIPTION
    This script helps remove a subscription that was created by your user account (delegated)
    so that a new subscription can be created by the Function App's managed identity.

.PARAMETER SubscriptionId
    The subscription ID to remove. Default: 69b82601-c3c8-446f-a72c-2384784cd404 (from error logs)

.EXAMPLE
    .\Remove-OldSubscription.ps1

.NOTES
    - You must be authenticated as the same user who created the subscription
    - Requires Subscription.ReadWrite.All delegated permission
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId = "69b82601-c3c8-446f-a72c-2384784cd404"
)

Import-Module Microsoft.Graph.ChangeNotifications
Import-Module Microsoft.Graph.Authentication

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Remove Old Microsoft Graph Subscription" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

Write-Host "This will remove subscription: $SubscriptionId" -ForegroundColor Yellow
Write-Host "This subscription was likely created by your user account and cannot" -ForegroundColor Yellow
Write-Host "be accessed by the Function App's managed identity.`n" -ForegroundColor Yellow

# Check if connected
$context = Get-MgContext
if (-not $context) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "Subscription.ReadWrite.All" -NoWelcome
}
else {
    Write-Host "✅ Already connected as: $($context.Account)" -ForegroundColor Green
}

# Try to get the subscription details first
Write-Host "`nFetching subscription details..." -ForegroundColor Cyan
try {
    $subscription = Get-MgSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop

    Write-Host "✅ Found subscription:" -ForegroundColor Green
    Write-Host "  Resource: $($subscription.Resource)" -ForegroundColor Gray
    Write-Host "  Change Types: $($subscription.ChangeType)" -ForegroundColor Gray
    Write-Host "  Expiration: $($subscription.ExpirationDateTime)" -ForegroundColor Gray
    Write-Host "  Created by App: $($subscription.ApplicationId)" -ForegroundColor Gray
}
catch {
    if ($_.Exception.Message -like "*does not belong to application*") {
        Write-Host "⚠️  Cannot read subscription - it belongs to a different application." -ForegroundColor Yellow
        Write-Host "This is expected if it was created by a different identity." -ForegroundColor Gray
    }
    elseif ($_.Exception.Message -like "*NotFound*") {
        Write-Host "✅ Subscription not found - may have already been deleted or expired." -ForegroundColor Green
        Write-Host "You can proceed to create a new subscription.`n" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$response = Read-Host "`nDelete this subscription? (y/N)"
if ($response -ne 'y' -and $response -ne 'Y') {
    Write-Host "Cancelled." -ForegroundColor Gray
    exit 0
}

Write-Host "`nDeleting subscription..." -ForegroundColor Cyan
try {
    Remove-MgSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
    Write-Host "✅ Subscription deleted successfully!" -ForegroundColor Green

    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "The old subscription has been removed." -ForegroundColor Green
    Write-Host "`n⚠️  IMPORTANT: To create a subscription the Function App can use:" -ForegroundColor Yellow
    Write-Host "`n1. Option A: Let the Function App create it automatically" -ForegroundColor White
    Write-Host "   - Deploy the function app" -ForegroundColor Gray
    Write-Host "   - The RenewSubscription function can create subscriptions if needed" -ForegroundColor Gray
    Write-Host "`n2. Option B: Use Azure Cloud Shell (RECOMMENDED)" -ForegroundColor White
    Write-Host "   - Go to Azure Portal -> Cloud Shell (bash or PowerShell)" -ForegroundColor Gray
    Write-Host "   - Install: Install-Module Microsoft.Graph.ChangeNotifications" -ForegroundColor Gray
    Write-Host "   - Run: Connect-MgGraph -Identity" -ForegroundColor Gray
    Write-Host "   - Upload and run create-api-subscription-topic.ps1" -ForegroundColor Gray
    Write-Host "`n3. Option C: Accept that local subscriptions won't work with Function App" -ForegroundColor White
    Write-Host "   - Create subscription locally for testing" -ForegroundColor Gray
    Write-Host "   - Accept it will expire in 3 days" -ForegroundColor Gray
    Write-Host "   - Function App would need its own subscription in production" -ForegroundColor Gray
}
catch {
    Write-Host "❌ Failed to delete subscription: $($_.Exception.Message)" -ForegroundColor Red

    if ($_.Exception.Message -like "*does not belong to application*") {
        Write-Host "`n⚠️  The subscription belongs to a different application." -ForegroundColor Yellow
        Write-Host "You need to authenticate as the user/app that created it, OR" -ForegroundColor Yellow
        Write-Host "wait for it to expire (max 3 days).`n" -ForegroundColor Yellow
    }
    exit 1
}
