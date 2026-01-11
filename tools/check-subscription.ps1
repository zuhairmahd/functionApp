<#
.SYNOPSIS
    Checks the status of Microsoft Graph change notification subscriptions.

.DESCRIPTION
    This script lists all active Graph API subscriptions and shows their expiration status.
    Useful for monitoring and troubleshooting subscription issues.

.EXAMPLE
    .\check-subscription.ps1
    Lists all Graph subscriptions and their status
#>
[CmdletBinding()]
param()

Import-Module Microsoft.Graph.ChangeNotifications

Write-Host "Checking Microsoft Graph subscriptions..." -ForegroundColor Cyan
Write-Host ""

try
{
    # Check if connected to Microsoft Graph
    $context = Get-MgContext
    if (-not $context)
    {
        Write-Host "Not connected to Microsoft Graph." -ForegroundColor Red
        Write-Host "Please connect first:" -ForegroundColor Yellow
        Write-Host "  Connect-MgGraph -Scopes 'Subscription.Read.All'" -ForegroundColor Yellow
        return
    }

    Write-Host "Connected as: $($context.Account)" -ForegroundColor Green
    Write-Host ""

    # Get all subscriptions
    $subscriptions = Get-MgSubscription -All

    if ($subscriptions.Count -eq 0)
    {
        Write-Host "No active subscriptions found." -ForegroundColor Yellow
        Write-Host "Note that if the subscription was created by a different owner, it won't be visible here." -ForegroundColor Yellow
        Write-Host "You must run this script as the same user or managed identity that created the subscription." -ForegroundColor Yellow
        Write-Host "Run .\create-api-subscription-topic.ps1 to create a subscription." -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($subscriptions.Count) subscription(s):" -ForegroundColor Green
    Write-Host ""

    foreach ($sub in $subscriptions)
    {
        $expirationDateTime = [DateTime]::Parse($sub.ExpirationDateTime)
        $hoursUntilExpiration = ($expirationDateTime - (Get-Date)).TotalHours

        Write-Host "Subscription ID: $($sub.Id)" -ForegroundColor Yellow
        Write-Host "  Resource: $($sub.Resource)"
        Write-Host "  Change types: $($sub.ChangeType)"
        Write-Host "  Notification URL: $($sub.NotificationUrl)"
        Write-Host "  Expiration: $expirationDateTime" -NoNewline

        if ($hoursUntilExpiration -lt 0)
        {
            Write-Host " [EXPIRED]" -ForegroundColor Red
            Write-Host "This subscription has expired and needs to be recreated!" -ForegroundColor Red
        }
        elseif ($hoursUntilExpiration -lt 24)
        {
            Write-Host " [EXPIRES SOON]" -ForegroundColor Yellow
            Write-Host "Expires in $([Math]::Round($hoursUntilExpiration, 1)) hours - renewal recommended!" -ForegroundColor Yellow
        }
        else
        {
            Write-Host " [ACTIVE]" -ForegroundColor Green
            Write-Host "Expires in $([Math]::Round($hoursUntilExpiration, 1)) hours" -ForegroundColor Green
        }

        Write-Host ""
    }

    # Check for EventGrid subscriptions specifically
    $eventGridSubs = $subscriptions | Where-Object { $_.NotificationUrl -like "*EventGrid*" }

    if ($eventGridSubs.Count -eq 0)
    {
        Write-Host "Warning: No subscriptions found using EventGrid" -ForegroundColor Yellow
        Write-Host "Your function app may not receive notifications." -ForegroundColor Yellow
    }
    else
    {
        Write-Host "Found $($eventGridSubs.Count) EventGrid subscription(s)" -ForegroundColor Green
    }
}
catch
{
    Write-Host "Error checking subscriptions:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Make sure you're connected to Microsoft Graph:" -ForegroundColor Yellow
    Write-Host "  Connect-MgGraph -Scopes 'Subscription.Read.All'" -ForegroundColor Yellow
}
