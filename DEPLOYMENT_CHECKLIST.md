# Azure Function Deployment Checklist

## Pre-Deployment Configuration

### 1. Managed Identity Setup (Critical)
The function app uses **managed identity** for authentication to Azure services and Microsoft Graph.

#### Azure Resources Access
✅ Already configured:
- Storage Account access (Storage Blob Data Contributor + Storage Queue Data Contributor needed)

#### Microsoft Graph API Permissions (Required for Entra ID operations)
⚠️ **Action Required**: Grant the following Microsoft Graph API permissions to the function app's managed identity:

Using Azure CLI:
```powershell
# Get the managed identity object ID
$functionAppName = "GroupChange"
$resourceGroup = "groupchange"
$objectId = az functionapp identity show --name $functionAppName --resource-group $resourceGroup --query principalId -o tsv

# Assign Microsoft Graph permissions
# User.Read.All - Read all users
# Group.Read.All - Read all groups
# Device.Read.All - Read all devices
# Device.ReadWrite.All - Write device properties (for tagging)

# Get Microsoft Graph App ID
$graphAppId = "00000003-0000-0000-c000-000000000000"

# Assign permissions (requires Global Administrator or Privileged Role Administrator)
az ad app permission add --id $objectId --api $graphAppId --api-permissions \
    df021288-bdef-4463-88db-98f22de89214=Role \  # User.Read.All
    5b567255-7703-4780-807c-7be8301ae99b=Role \  # Group.Read.All
    7438b122-aefc-4978-80ed-43db9fcc7715=Role \  # Device.Read.All
    1138cb37-bd11-4084-a2b7-9f71582aeddb=Role    # Device.ReadWrite.All

# Grant admin consent
az ad app permission admin-consent --id $objectId
```

Or use Azure Portal:
1. Go to Azure Portal → Entra ID → Enterprise Applications
2. Find your function app's managed identity (search for "GroupChange")
3. Go to Permissions → Add Permission → Microsoft Graph → Application Permissions
4. Add: User.Read.All, Group.Read.All, Device.Read.All, Device.ReadWrite.All
5. Click "Grant admin consent"

### 2. Storage Account Configuration
✅ Storage account: `groupchange`
✅ Storage queue created: `outqueue` (for function output logging)

Verify managed identity has these roles on the storage account:
- **Storage Blob Data Contributor** (for blob access)
- **Storage Queue Data Contributor** (for queue access)

```powershell
# Verify role assignments
az role assignment list --scope "/subscriptions/8a89e116-824d-4eeb-8ef4-16dcc1f0959b/resourceGroups/groupchange/providers/Microsoft.Storage/storageAccounts/groupchange" --query "[?principalId=='b0c0908b-9eb2-4fcb-a2cd-8664c81aa170'].roleDefinitionName"
```

### 3. Application Insights
✅ Configured in local.settings.json
✅ Connection string present

### 4. Event Grid Subscription
The function expects Event Grid events for Microsoft.Graph.DirectoryChange events.

**Action Required**: Create Event Grid subscription to trigger this function:
```powershell
# Example Event Grid subscription creation
az eventgrid event-subscription create \
    --name groupchange-subscription \
    --source-resource-id "/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.Graph/..." \
    --endpoint-type azurefunction \
    --endpoint "/subscriptions/8a89e116-824d-4eeb-8ef4-16dcc1f0959b/resourceGroups/groupchange/providers/Microsoft.Web/sites/GroupChange/functions/EventGridTrigger1" \
    --included-event-types Microsoft.Graph.DirectoryChange
```

## Best Practices Compliance

### ✅ Implemented
- Extension bundle v4 (latest)
- Managed dependencies for PowerShell modules
- Flex Consumption plan (FC1)
- Application Insights enabled
- Managed identity authentication
- HTTPS-only storage access
- Dynamic concurrency enabled
- Retry policies configured

### ⚠️ Recommendations
1. **Remove bundled modules folder** from repository - now using managed dependencies
2. **Test function locally** using Azurite before deployment
3. **Configure private endpoints** for storage if needed for enhanced security
4. **Set up alerts** in Application Insights for function failures
5. **Review and adjust** retry policies based on workload

## Local Development

### Prerequisites
- Azure Functions Core Tools v4
- PowerShell 7.2+
- Azurite (for local storage emulation)

### Testing Locally
```powershell
# Start Azurite
azurite --silent --location ./__azurite__ --debug ./__azurite__/debug.log

# Run function
func start
```

### Testing Event Grid Trigger
Use the test-events.http file or VS Code REST Client extension to send test events.

## Deployment Commands

### Deploy using Azure Functions Core Tools
```powershell
func azure functionapp publish GroupChange
```

### Deploy using Azure CLI
```powershell
az functionapp deployment source config-zip \
    --resource-group groupchange \
    --name GroupChange \
    --src deploy.zip
```

## Post-Deployment Verification

1. Check function status: `az functionapp show --name GroupChange --resource-group groupchange`
2. View logs: Azure Portal → Function App → Log Stream
3. Test with sample Event Grid event
4. Monitor in Application Insights

## Troubleshooting

### Common Issues
1. **"Unauthorized" errors**: Check managed identity Microsoft Graph permissions
2. **Storage access denied**: Verify RBAC role assignments on storage account
3. **Module not found**: Ensure requirements.psd1 is deployed and managed dependencies enabled
4. **Function not triggering**: Verify Event Grid subscription is configured correctly

### Debug Commands
```powershell
# Check function app settings
az functionapp config appsettings list --name GroupChange --resource-group groupchange

# View function keys
az functionapp keys list --name GroupChange --resource-group groupchange

# Stream logs
az webapp log tail --name GroupChange --resource-group groupchange
```

## Security Checklist
- [ ] Managed identity has minimal required permissions (least privilege)
- [ ] Microsoft Graph API permissions are application-level (not delegated)
- [ ] Storage account has public access disabled
- [ ] Function app has authentication enabled (if exposing HTTP endpoints)
- [ ] Application Insights data retention configured
- [ ] Secrets stored in Key Vault (if any)
- [ ] Network isolation configured (VNet integration, private endpoints)

## Monitoring
- Application Insights → Performance
- Application Insights → Failures
- Azure Monitor → Metrics (Function execution count, duration, failures)
- Storage account metrics (queue depth, blob operations)
