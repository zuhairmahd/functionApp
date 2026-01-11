<#
.SYNOPSIS
    Creates a Microsoft Graph change notification subscription for group changes.

.DESCRIPTION
    This script creates a subscription to receive notifications when groups are created, updated, or deleted.
    The subscription is configured to send events to Azure EventGrid Partner Topic.

    Maximum expiration time for Graph subscriptions is 4230 minutes (~3 days).
    A renewal function should be deployed to keep the subscription active.

.PARAMETER UseServicePrincipal
    Use the managed identity's service principal credentials to create the subscription.
    This ensures the subscription is owned by the same identity that the Function App uses.

.PARAMETER ClientId
    The client ID of the managed identity. Default: 0ed597a6-5cca-4c6f-b51e-10510010e936

.PARAMETER TenantId
    The Azure AD tenant ID.

.EXAMPLE
    # For local testing (subscription won't work with Function App)
    Connect-MgGraph -Scopes "Group.Read.All"
    .\create-api-subscription-topic.ps1

.EXAMPLE
    # To create subscription that Function App can use (requires certificate or secret)
    .\create-api-subscription-topic.ps1 -UseServicePrincipal -TenantId "your-tenant-id"

.NOTES
    - Requires Microsoft.Graph.ChangeNotifications module
    - Requires appropriate Graph API permissions (Group.Read.All)
    - The subscription ID is saved to subscription-info.json for renewal purposes

    IMPORTANT: For the subscription to work with the Azure Function, it MUST be created
    using the same identity (managed identity) that the Function App uses.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$UseServicePrincipal,
    [Parameter()]
    [string]$ClientId,
    [Parameter()]
    [string]$TenantId,
    [Parameter()]
    [string]$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b",
    [Parameter()]
    [string]$resourceGroup = "groupchangefunction",
    [Parameter()]
    [string]$partnerTopic = "groupchangefunctiontopic",
    [Parameter()]
    [string]$location = "centralus",
    [Parameter()]
    [int]$expirationMinutes = 4230
)

Import-Module Microsoft.Graph.ChangeNotifications
Import-Module Microsoft.Graph.Authentication

# Set expiration to the passed value, or to the default maximum allowed (4230 minutes = ~3 days)
$expirationDate = (Get-Date).AddMinutes($expirationMinutes)

# Authenticate to Microsoft Graph
if ($UseServicePrincipal)
{
    if (-not $TenantId)
    {
        Write-Host "TenantId is required when using -UseServicePrincipal" -ForegroundColor Red
        Write-Host "Get your tenant ID from: https://portal.azure.com -> Entra ID -> Overview" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Warning: SERVICE PRINCIPAL AUTHENTICATION" -ForegroundColor Yellow
    Write-Host "Managed identities cannot authenticate from local machines." -ForegroundColor Yellow
    Write-Host "You need to create an App Registration with certificate or secret authentication." -ForegroundColor Yellow
    Write-Host "`nAlternative: Run this command from Azure Cloud Shell or an Azure VM where the" -ForegroundColor Yellow
    Write-Host "managed identity is assigned, then use: Connect-MgGraph -Identity" -ForegroundColor Yellow
    exit 1
}
else
{
    # Check if already connected
    $context = Get-MgContext
    if (-not $context)
    {
        Write-Host "Not connected to Microsoft Graph." -ForegroundColor Yellow
        Write-Host "Connecting with user authentication (delegated permissions)..." -ForegroundColor Cyan
        Write-Host "`nWARNING: This will create a subscription under YOUR account," -ForegroundColor Yellow
        Write-Host "which the Function App's managed identity CANNOT access." -ForegroundColor Yellow
        Write-Host "`nTo create a subscription the Function App can use, you must:" -ForegroundColor Yellow
        Write-Host "  1. Run this from Azure Cloud Shell with the managed identity, OR" -ForegroundColor Yellow
        Write-Host "  2. Delete the subscription later and let the Function App create it" -ForegroundColor Yellow

        $response = Read-Host "`nContinue anyway? (y/N)"
        if ($response -ne 'y' -and $response -ne 'Y')
        {
            Write-Host "Cancelled." -ForegroundColor Gray
            exit 0
        }
        Connect-MgGraph -Scopes "Group.Read.All" -NoWelcome
    }
    else
    {
        Write-Host "Connected to Microsoft Graph as: $($context.Account)" -ForegroundColor Green
        Write-Host "`nWARNING: Creating subscription under this account." -ForegroundColor Yellow
        Write-Host "The Function App's managed identity will NOT be able to renew this subscription." -ForegroundColor Yellow
    }
}

Write-Host "`nCreating Microsoft Graph subscription..." -ForegroundColor Cyan
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

try
{
    $subscription = New-MgSubscription -BodyParameter $params

    Write-Host "`nSubscription created successfully!" -ForegroundColor Green
    Write-Host "  Subscription ID: $($subscription.Id)" -ForegroundColor Yellow
    Write-Host "  Expires at: $($subscription.ExpirationDateTime)" -ForegroundColor Yellow

    # Save subscription information for renewal
    $subscriptionInfo = @{
        SubscriptionId           = $subscription.Id
        Resource                 = $subscription.Resource
        ChangeType               = $subscription.ChangeType
        ExpirationDateTime       = $subscription.ExpirationDateTime
        CreatedDateTime          = (Get-Date).ToString("o")
        NotificationUrl          = $params.notificationUrl
        LifecycleNotificationUrl = $params.lifecycleNotificationUrl
        ClientState              = $params.clientState
    }

    $subscriptionInfo | ConvertTo-Json -Depth 10 | Set-Content -Path "subscription-info.json"
    Write-Host "`nSubscription info saved to subscription-info.json" -ForegroundColor Green

    # Calculate renewal time (renew 1 day before expiration)
    $renewalTime = $expirationDate.AddDays(-1)
    Write-Host "`nIMPORTANT: Schedule renewal before $renewalTime" -ForegroundColor Yellow
    Write-Host "Run .\renew-subscription.ps1 or deploy the RenewSubscription function" -ForegroundColor Yellow

    return $subscription
}
catch
{
    Write-Host "`nError creating subscription:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nMake sure you have:" -ForegroundColor Yellow
    Write-Host "  1. Connected to Microsoft Graph (Connect-MgGraph)" -ForegroundColor Yellow
    Write-Host "  2. Appropriate permissions (Group.Read.All)" -ForegroundColor Yellow
    Write-Host "  3. Partner topic is activated in Azure" -ForegroundColor Yellow
    throw
}