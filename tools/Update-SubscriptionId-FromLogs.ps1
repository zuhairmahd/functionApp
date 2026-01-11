<#
.SYNOPSIS
    Updates the Function App's GRAPH_SUBSCRIPTION_ID setting from the logs.

.DESCRIPTION
    After the RenewSubscription function creates a new subscription, the subscription ID
    needs to be stored in the Function App's application settings for optimal performance.
    This script extracts the new subscription ID from the logs and updates the setting.

.PARAMETER FunctionAppName
    Name of the Function App. Default: groupchangefunction

.PARAMETER ResourceGroupName
    Resource group containing the Function App. Default: groupchangefunction

.EXAMPLE
    .\Update-SubscriptionId-FromLogs.ps1

.NOTES
    Requires Az.Functions module and appropriate permissions to update Function App settings
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$FunctionAppName = "groupchangefunction",
    [Parameter()]
    [string]$ResourceGroupName = "groupchangefunction"
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Update Function App Subscription ID" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Check if Az.Functions module is installed
if (-not (Get-Module -ListAvailable Az.Functions))
{
    Write-Host "Az.Functions module not installed" -ForegroundColor Yellow
    Write-Host "Installing Az.Functions module..." -ForegroundColor Cyan
    Install-Module Az.Functions -Scope CurrentUser -Force -AllowClobber
}

Import-Module Az.Functions
Import-Module Az.OperationalInsights

# Check Azure login
$context = Get-AzContext
if (-not $context)
{
    Write-Host "Not logged in to Azure" -ForegroundColor Yellow
    Connect-AzAccount
}

Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green

# Query Application Insights for the subscription ID from logs
Write-Host "`nSearching for newly created subscription ID in logs..." -ForegroundColor Cyan

# Get the Function App's Application Insights workspace
$functionApp = Get-AzFunctionApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName
if (-not $functionApp)
{
    Write-Host "Function App not found: $FunctionAppName" -ForegroundColor Red
    exit 1
}

Write-Host "Found Function App: $FunctionAppName" -ForegroundColor Green

# Look in recent traces for the subscription creation log
Write-Host "Searching recent logs for subscription creation..." -ForegroundColor Cyan

# Alternative: Parse from diagnostic logs if available
$query = @"
traces
| where timestamp > ago(24h)
| where message contains "SUCCESS: Created new subscription"
| project timestamp, message
| order by timestamp desc
| take 1
"@

try
{
    # This requires Application Insights to be configured
    $appInsightsId = $functionApp.ApplicationInsightsConnectionString
    if ($appInsightsId)
    {
        Write-Host "Querying Application Insights..." -ForegroundColor Gray
        # Query would go here if AI is properly configured
        Write-Host "Application Insights query not implemented in this version" -ForegroundColor Yellow
    }
}
catch
{
    Write-Host "Could not query Application Insights: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Manual input as fallback
Write-Host "`nEnter the new subscription ID from the Function App logs:" -ForegroundColor Yellow
Write-Host "(Check Azure Portal -> Function App -> Monitor -> Logs for messages like:" -ForegroundColor Gray
Write-Host " 'SUCCESS: Created new subscription <GUID>')" -ForegroundColor Gray
$newSubscriptionId = Read-Host "`nSubscription ID"

if (-not $newSubscriptionId -or $newSubscriptionId.Length -ne 36)
{
    Write-Host "Invalid subscription ID format. Expected GUID like: 12345678-1234-1234-1234-123456789abc" -ForegroundColor Red
    exit 1
}

Write-Host "`nUpdating Function App setting..." -ForegroundColor Cyan
Write-Host "   Setting: GRAPH_SUBSCRIPTION_ID" -ForegroundColor Gray
Write-Host "   Value: $newSubscriptionId" -ForegroundColor Gray

try
{
    # Get current settings
    $settings = $functionApp.ApplicationSettings

    # Update or add the setting
    $settings['GRAPH_SUBSCRIPTION_ID'] = $newSubscriptionId

    # Update the Function App
    Update-AzFunctionAppSetting -ResourceGroupName $ResourceGroupName `
        -Name $FunctionAppName `
        -AppSetting $settings `
        -Force

    Write-Host "`nSuccessfully updated GRAPH_SUBSCRIPTION_ID!" -ForegroundColor Green
    Write-Host "   The Function App will now use this subscription ID directly" -ForegroundColor Green
    Write-Host "   instead of querying all subscriptions on each run." -ForegroundColor Green

    Write-Host "`nNote: Function App will restart to pick up the new setting" -ForegroundColor Yellow
}
catch
{
    Write-Host "`nFailed to update Function App settings: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nManual update:" -ForegroundColor Yellow
    Write-Host "1. Go to Azure Portal" -ForegroundColor White
    Write-Host "2. Navigate to Function App: $FunctionAppName" -ForegroundColor White
    Write-Host "3. Settings -> Configuration -> Application settings" -ForegroundColor White
    Write-Host "4. Add or update: GRAPH_SUBSCRIPTION_ID = $newSubscriptionId" -ForegroundColor White
    Write-Host "5. Save and restart the Function App" -ForegroundColor White
    exit 1
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "Update Complete!" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan
