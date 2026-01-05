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

$renewalThreshhold = 24
Import-Module Microsoft.Graph.ChangeNotifications

# If no SubscriptionId provided, try to read from saved file
if (-not $SubscriptionId)
{
    $infoFile = "subscription-info.json"
    if (Test-Path $infoFile)
    {
        Write-Host "Reading subscription info from $infoFile..." -ForegroundColor Cyan
        $subscriptionInfo = Get-Content $infoFile | ConvertFrom-Json
        $SubscriptionId = $subscriptionInfo.SubscriptionId
    }
    else
    {
        # Try to find subscription by querying all subscriptions for this resource
        try
        {
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Microsoft Graph using Managed Identity"
            Connect-MgGraph -NoWelcome
            Write-Host "Connected to Microsoft Graph"
            $allSubscriptions = Get-MgSubscription -All
            Write-Host "Got $($allSubscriptions.Count) total subscriptions  "

            # Filter for subscriptions that use EventGrid and match our resource
            $global:relevantSubscriptions = $allSubscriptions | Where-Object {
                $_.NotificationUrl -like "*EventGrid*" -and
                $_.Resource -eq "groups"
            } | Select-Object -First 1
            Write-Host "Filtering for subscriptions with resource 'groups' and EventGrid notification URL"
            if ($relevantSubscriptions.Count -eq 0)
            {
                Write-Host "No subscriptions found..." -ForegroundColor Red
                exit 1
            }
            $SubscriptionId = $relevantSubscriptions.id
            Write-Host "Found subscription ID: $SubscriptionId"
        }
        catch
        {
            Write-Error "Failed to connect to Microsoft Graph or query subscriptions: $($_.Exception.Message)"
            $diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: Failed to connect to Microsoft Graph - $($_.Exception.Message)"
            Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")
            throw
        }
    }
}

# Get current subscription details first
Write-Host "`nFetching current subscription details..." -ForegroundColor Cyan
try
{
    $currentSubscription = Get-MgSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
    Write-Host "  Current expiration: $($currentSubscription.ExpirationDateTime)" -ForegroundColor Gray
    Write-Host "  Resource: $($currentSubscription.Resource)" -ForegroundColor Gray
}
catch
{
    Write-Error "Failed to fetch subscription details: $($_.Exception.Message)"
    exit 1
}

#Check if we have less than 24 hours to expiration
$expirationDateTime = [DateTime]::Parse($currentSubscription.ExpirationDateTime)
$hoursUntilExpiration = ($expirationDateTime - (Get-Date)).TotalHours
Write-Host "  Hours until expiration: $([Math]::Round($hoursUntilExpiration, 2))"
if ($hoursUntilExpiration -lt $renewalThreshhold)
{
    Write-Host "Renewing subscription: $SubscriptionId" -ForegroundColor Cyan
    # Set new expiration to maximum allowed (4230 minutes = ~3 days)
    $expirationMinutes = 4230
    $newExpirationDate = (Get-Date).AddMinutes($expirationMinutes)
    Write-Host "  New expiration: $newExpirationDate ($expirationMinutes minutes)" -ForegroundColor Gray
    try
    {

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
        if (Test-Path "subscription-info.json")
        {
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
    catch
    {
        Write-Host "`nError renewing subscription:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red

        if ($_.Exception.Message -like "*ResourceNotFound*" -or $_.Exception.Message -like "*does not exist*")
        {
            Write-Host "`nThe subscription may have expired or been deleted." -ForegroundColor Yellow
            Write-Host "Run .\create-api-subscription-topic.ps1 to create a new subscription." -ForegroundColor Yellow
        }

        throw
    }
}
else
{
    Write-Host "`nNo renewal needed. Subscription is valid for more than $renewalThreshhold hours." -ForegroundColor Green
}