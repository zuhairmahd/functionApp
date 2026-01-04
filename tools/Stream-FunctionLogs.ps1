<#
.SYNOPSIS
    Streams live logs from the Azure Function App.

.DESCRIPTION
    This script streams live execution logs from the Function App.
    It tries multiple methods:
    1. Azure Functions Core Tools (func) - Recommended
    2. Azure CLI (az webapp log tail) - Requires file system logging enabled

    If file system logging is not enabled, the script will attempt to enable it.

.PARAMETER FunctionAppName
    The name of the Function App. Default: groupchangefunction

.PARAMETER ResourceGroup
    The resource group name. Default: groupchangefunction

.PARAMETER UseAzCli
    Force using Azure CLI instead of Functions Core Tools

.EXAMPLE
    .\Stream-FunctionLogs.ps1
    Streams logs using Functions Core Tools (if available)

.EXAMPLE
    .\Stream-FunctionLogs.ps1 -UseAzCli
    Streams logs using Azure CLI

.NOTES
    Preferred: Azure Functions Core Tools (func azure functionapp logstream)
    Alternative: Azure CLI (requires logging configuration)
    Press Ctrl+C to stop streaming.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$FunctionAppName = "groupchangefunction",

    [Parameter()]
    [string]$ResourceGroup = "groupchangefunction",

    [Parameter()]
    [switch]$UseAzCli
)

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Azure Function App Live Log Stream" -ForegroundColor Cyan
Write-Host "================================================`n" -ForegroundColor Cyan

Write-Host "Function App: $FunctionAppName" -ForegroundColor Yellow
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "`nPress Ctrl+C to stop streaming...`n" -ForegroundColor Gray

# Try Azure Functions Core Tools first (preferred method)
$funcExists = Get-Command func -ErrorAction SilentlyContinue

if ($funcExists -and -not $UseAzCli)
{
    Write-Host "Using Azure Functions Core Tools (func)..." -ForegroundColor Cyan
    Write-Host "================================================`n" -ForegroundColor Cyan

    try
    {
        func azure functionapp logstream $FunctionAppName
    }
    catch
    {
        Write-Host "`n❌ Error streaming logs with func: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "`nTrying Azure CLI instead...`n" -ForegroundColor Yellow
        $UseAzCli = $true
    }
}

if ($UseAzCli -or -not $funcExists)
{
    if (-not $funcExists)
    {
        Write-Host "Azure Functions Core Tools not found. Using Azure CLI..." -ForegroundColor Yellow
    }

    Write-Host "Configuring log settings..." -ForegroundColor Cyan
    Write-Host "================================================`n" -ForegroundColor Cyan

    try
    {
        # Enable application logging first (required for log streaming)
        Write-Host "Enabling application logging..." -ForegroundColor Gray
        az webapp log config `
            --name $FunctionAppName `
            --resource-group $ResourceGroup `
            --application-logging filesystem `
            --level verbose `
            --detailed-error-messages true `
            --failed-request-tracing true `
            2>$null

        Write-Host "✓ Logging enabled`n" -ForegroundColor Green
        Write-Host "Starting log stream..." -ForegroundColor Cyan
        Write-Host "================================================`n" -ForegroundColor Cyan

        # Stream logs using Azure CLI
        az webapp log tail `
            --name $FunctionAppName `
            --resource-group $ResourceGroup
    }
    catch
    {
        Write-Host "`n❌ Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "`nTroubleshooting steps:" -ForegroundColor Yellow
        Write-Host "  1. Verify Azure CLI is installed: az --version" -ForegroundColor Gray
        Write-Host "  2. Ensure you're logged in: az login" -ForegroundColor Gray
        Write-Host "  3. Check the function app exists: az functionapp show --name $FunctionAppName --resource-group $ResourceGroup" -ForegroundColor Gray
        Write-Host "  4. Install Azure Functions Core Tools for better log streaming:" -ForegroundColor Gray
        Write-Host "     npm install -g azure-functions-core-tools@4" -ForegroundColor Gray
    }
}
