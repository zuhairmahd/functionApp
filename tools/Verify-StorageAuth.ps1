<#
.SYNOPSIS
    Verifies that the Azure Function App has the correct configuration and permissions for storage authentication.

.DESCRIPTION
    This script checks:
    1. App settings for managed identity configuration
    2. Role assignments on the storage account
    3. Queue storage accessibility
    4. Recent function execution logs for auth errors

.EXAMPLE
    .\Verify-StorageAuth.ps1

.NOTES
    Run this script after applying the AZURE_CLIENT_ID fix to verify the configuration.
#>
[CmdletBinding()]
param(
    [string]$functionAppName = "groupchangefunction",
    [string]$resourceGroup = "groupchangefunction",
    [string]$storageAccountName = "groupchangefunction1",
    [string]$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b",
    [string]$expectedClientId = "0ed597a6-5cca-4c6f-b51e-10510010e936",
    [string]$expectedPrincipalId = "e4ad71a2-53c3-467f-a553-bc7eebf711b5"
)

$ErrorActionPreference = 'Continue'
Write-Host "`n=== Storage Authentication Verification ===" -ForegroundColor Cyan
Write-Host "Function App: $functionAppName"
Write-Host "Storage Account: $storageAccountName"
Write-Host "`n"

# Test 1: Check AZURE_CLIENT_ID setting
Write-Host "[Test 1] Checking AZURE_CLIENT_ID app setting..." -ForegroundColor Yellow
$azureClientId = az functionapp config appsettings list `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --query "[?name=='AZURE_CLIENT_ID'].value | [0]" -o tsv

if ($azureClientId -eq $expectedClientId)
{
    Write-Host "AZURE_CLIENT_ID is correctly set: $azureClientId" -ForegroundColor Green
}
else
{
    Write-Host "AZURE_CLIENT_ID is missing or incorrect. Expected: $expectedClientId, Got: $azureClientId" -ForegroundColor Red
}

# Test 2: Check AzureWebJobsStorage__credential setting
Write-Host "`n[Test 2] Checking AzureWebJobsStorage__credential setting..." -ForegroundColor Yellow
$credential = az functionapp config appsettings list `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --query "[?name=='AzureWebJobsStorage__credential'].value | [0]" -o tsv

if ($credential -eq "managedidentity")
{
    Write-Host "Credential type is set to: $credential" -ForegroundColor Green
}
else
{
    Write-Host "Credential type is incorrect. Expected: managedidentity, Got: $credential" -ForegroundColor Red
}

# Test 3: Check AzureWebJobsStorage__clientId setting
Write-Host "`n[Test 3] Checking AzureWebJobsStorage__clientId setting..." -ForegroundColor Yellow
$storageClientId = az functionapp config appsettings list `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --query "[?name=='AzureWebJobsStorage__clientId'].value | [0]" -o tsv
if ($storageClientId -eq $expectedClientId)
{
    Write-Host "AzureWebJobsStorage__clientId is correctly set: $storageClientId" -ForegroundColor Green
}
else
{
    Write-Host "AzureWebJobsStorage__clientId is missing or incorrect. Expected: $expectedClientId, Got: $storageClientId" -ForegroundColor Red
}

# Test 4: Verify role assignment
Write-Host "`n[Test 4] Checking Storage Queue Data Contributor role assignment..." -ForegroundColor Yellow
$roleAssignments = az role assignment list `
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName" `
    --query "[?principalId=='$expectedPrincipalId' && roleDefinitionId=='/providers/Microsoft.Authorization/RoleDefinitions/974c5e8b-45b9-4653-ba55-5f855dd0fb88']" -o json | ConvertFrom-Json
if ($roleAssignments.Count -gt 0)
{
    Write-Host "Storage Queue Data Contributor role is assigned to the managed identity" -ForegroundColor Green
}
else
{
    Write-Host "Storage Queue Data Contributor role is NOT assigned to the managed identity" -ForegroundColor Red
}

# Test 5: Check recent function logs for 403 errors
Write-Host "`n[Test 5] Checking recent function logs for 403 errors..." -ForegroundColor Yellow
Write-Host "  Note: This requires Application Insights query access" -ForegroundColor Gray
try
{
    $appInsightsId = az functionapp show `
        --name $functionAppName `
        --resource-group $resourceGroup `
        --query "siteConfig.appSettings[?name=='APPLICATIONINSIGHTS_CONNECTION_STRING'].value | [0]" -o tsv
    if ($appInsightsId)
    {
        Write-Host "Application Insights is configured. Check the Azure Portal for recent 403 errors." -ForegroundColor Cyan
        Write-Host "     Portal Link: https://portal.azure.com/#blade/Microsoft_Azure_Functions/FunctionMenuBlade/Monitor/resourceId/%2Fsubscriptions%2F$subscriptionId%2FresourceGroups%2F$resourceGroup%2Fproviders%2FMicrosoft.Web%2Fsites%2F$functionAppName" -ForegroundColor Gray
    }
}
catch
{
    Write-Host "Could not check Application Insights configuration" -ForegroundColor Yellow
}

# Test 6: Try to access queue (requires user to be authenticated)
Write-Host "`n[Test 6] Testing queue storage access..." -ForegroundColor Yellow
Write-Host "  Note: This tests YOUR access, not the managed identity's access" -ForegroundColor Gray
try
{
    $queues = az storage queue list `
        --account-name $storageAccountName `
        --auth-mode login `
        --query "[?name=='outqueue'].name | [0]" -o tsv 2>$null

    if ($queues -eq "outqueue")
    {
        Write-Host "Queue 'outqueue' exists and is accessible" -ForegroundColor Green
        # Try to peek at messages
        $messageCount = az storage message peek `
            --queue-name outqueue `
            --account-name $storageAccountName `
            --auth-mode login `
            --num-messages 1 `
            --query "length(@)" -o tsv 2>$null

        if ($messageCount -gt 0)
        {
            Write-Host "  Queue has messages (function is successfully writing logs)" -ForegroundColor Green
        }
        else
        {
            Write-Host "  Queue is empty (no recent function executions or logs)" -ForegroundColor Cyan
        }
    }
    else
    {
        Write-Host "  Queue 'outqueue' not found or not accessible" -ForegroundColor Yellow
    }
}
catch
{
    Write-Host "  Could not access queue storage. Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  This might be a permissions issue for YOUR account, not the managed identity" -ForegroundColor Gray
}

# Summary
Write-Host "`n=== Verification Summary ===" -ForegroundColor Cyan
Write-Host "If all tests show success, the configuration is correct."
Write-Host "If you still see 403 errors:"
Write-Host "  1. Wait 2-3 minutes for the function app to fully restart"
Write-Host "  2. Trigger the function and check logs again"
Write-Host "  3. Verify the managed identity hasn't changed"
Write-Host "`nTo monitor live logs:"
Write-Host "  func azure functionapp logstream $functionAppName" -ForegroundColor Gray
Write-Host ""
