# Troubleshooting: 403 Authorization Error for Queue Storage Output Binding

## Problem Description

The EventGridTrigger1 function executes successfully (Microsoft Graph operations work), but fails at the end with a 403 `AuthorizationPermissionMismatch` error when writing logs to Azure Queue Storage via the output binding:

```
Error: This request is not authorized to perform this operation using this permission.
ErrorCode: AuthorizationPermissionMismatch
Server: Windows-Azure-Queue/1.0
```

## Root Cause

The Azure Functions runtime requires explicit configuration to use a **user-assigned managed identity** for **output bindings**. While the app settings included `AzureWebJobsStorage__clientId` and `AzureWebJobsStorage__credential=managedidentity`, the runtime also needs the `AZURE_CLIENT_ID` environment variable to ensure ALL Azure SDK operations (including output bindings) use the correct managed identity.

## Solution Applied

### Step 1: Added AZURE_CLIENT_ID App Setting ✅

Added the environment variable that tells the Azure Identity SDK which managed identity to use:

```powershell
az functionapp config appsettings set \
    --name groupchangefunction \
    --resource-group groupchangefunction \
    --settings AZURE_CLIENT_ID="0ed597a6-5cca-4c6f-b51e-10510010e936"
```

This setting ensures the Functions runtime uses the user-assigned managed identity `groupchangefunction-identities-9bef22` (Client ID: `0ed597a6-5cca-4c6f-b51e-10510010e936`) for all operations.

### Step 2: Verify Role Assignments ✅

Confirmed the managed identity has the required permissions on the storage account `groupchangefunction1`:

- ✅ **Storage Queue Data Contributor** (Role ID: `974c5e8b-45b9-4653-ba55-5f855dd0fb88`)
  - Scope: `/subscriptions/8a89e116-824d-4eeb-8ef4-16dcc1f0959b/resourceGroups/groupchangefunction/providers/Microsoft.Storage/storageAccounts/groupchangefunction1`
  - Principal ID: `e4ad71a2-53c3-467f-a553-bc7eebf711b5`

- ✅ **Storage Blob Data Contributor** (Role ID: `0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3`)
- ✅ **Storage Blob Data Reader** (Role ID: `ba92f5b4-2d11-453d-a403-e96b0029c9fe`)
- ✅ **Storage Account Contributor** (Role ID: `17d1049b-9a84-46fb-8f53-869881c3d3ab`)

## Configuration Summary

### App Settings (Correctly Configured)

| Setting Name | Value |
|--------------|-------|
| `AZURE_CLIENT_ID` | `0ed597a6-5cca-4c6f-b51e-10510010e936` |
| `AzureWebJobsStorage__credential` | `managedidentity` |
| `AzureWebJobsStorage__clientId` | `0ed597a6-5cca-4c6f-b51e-10510010e936` |
| `AzureWebJobsStorage__queueServiceUri` | `https://groupchangefunction1.queue.core.windows.net` |
| `AzureWebJobsStorage__blobServiceUri` | `https://groupchangefunction1.blob.core.windows.net` |
| `AzureWebJobsStorage__tableServiceUri` | `https://groupchangefunction1.table.core.windows.net` |
| `AzureWebJobsStorage__accountName` | `groupchangefunction1` |

### function.json Output Binding

```json
{
  "type": "queue",
  "direction": "out",
  "name": "log",
  "queueName": "outqueue",
  "connection": "AzureWebJobsStorage"
}
```

## Testing the Fix

After the function app restarts (automatic after settings change), test the EventGridTrigger1 function by sending a CloudEvent. The logs should now be written to the `outqueue` without 403 errors.

### Expected Behavior
1. Function receives CloudEvent
2. Processes device tagging logic successfully
3. **Writes diagnostic logs to queue storage using managed identity** (previously failing)
4. Disconnects from Microsoft Graph
5. Completes without errors

## Additional Notes

### Why AZURE_CLIENT_ID is Required

The Azure Functions runtime uses multiple authentication mechanisms:

1. **AzureWebJobsStorage__*** settings: Used by the Functions host for internal operations
2. **AZURE_CLIENT_ID**: Used by Azure SDK clients and output bindings to select the correct managed identity

When a function app has **multiple managed identities** (system-assigned + user-assigned), the `AZURE_CLIENT_ID` environment variable tells the DefaultAzureCredential which one to prefer.

### Alternative Solution (Not Recommended)

Instead of user-assigned managed identity, you could:
- Use system-assigned managed identity only (simpler but less flexible)
- Use connection strings with access keys (less secure, not recommended)

### Monitoring

Check for successful queue writes:

```powershell
# View queue messages
az storage message peek --queue-name outqueue --account-name groupchangefunction1 --auth-mode login

# Check function execution logs
func azure functionapp logstream groupchangefunction
```

## References

- [Azure Functions managed identity](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity)
- [Identity-based connections for Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference?tabs=blob#configure-an-identity-based-connection)
- [Azure Storage Queue Data Contributor role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#storage-queue-data-contributor)
