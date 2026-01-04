# Microsoft Graph Subscription Management

This directory contains scripts and functions to manage Microsoft Graph change notification subscriptions for the Function App.

## Files

### Scripts (Run locally)

- **create-api-subscription-topic.ps1** - Creates a new Microsoft Graph subscription with 3-day expiration
- **renew-subscription.ps1** - Manually renews an existing subscription
- **check-subscription.ps1** - Checks the status of active subscriptions
- **grant-graph-permissions.ps1** - Grants Microsoft Graph permissions to the user-assigned managed identity
- **Get-FunctionLogs.ps1** - Retrieves function execution logs from Application Insights
- **Stream-FunctionLogs.ps1** - Streams live logs from the Function App

### Azure Function (Auto-renewal)

- **RenewSubscription/** - Timer-triggered function that automatically renews subscriptions every 12 hours

## Quick Start

### 1. Initial Setup

First, connect to Microsoft Graph with required permissions:

```powershell
Connect-MgGraph -Scopes "Subscription.Read.All", "Group.Read.All"
```

### 2. Create the Subscription

Run the creation script:

```powershell
.\create-api-subscription-topic.ps1
```

This will:
- Create a subscription with 4230-minute (3-day) expiration
- Save subscription info to `subscription-info.json`
- Display the subscription ID and expiration time

### 3. Grant Microsoft Graph Permissions to the Managed Identity

The Function App uses a **user-assigned managed identity** named `groupchangefunction-identities-9bef22`. This identity needs permissions to manage Microsoft Graph subscriptions.

Run the permission grant script:

```powershell
.\grant-graph-permissions.ps1
```

This script will:
- Grant `Subscription.Read.All` permission
- Grant `Subscription.ReadWrite.All` permission
- Grant `Group.Read.All` permission

**Note**: You must be a Global Administrator or Privileged Role Administrator to grant these permissions.

#### Manual Permission Grant (Alternative)

If you prefer to grant permissions manually:

```powershell
# User-assigned managed identity details
$principalId = "e4ad71a2-53c3-467f-a553-bc7eebf711b5"  # Object ID of the managed identity
$managedIdentityName = "groupchangefunction-identities-9bef22"

# Get Microsoft Graph Service Principal
$graphSP = Get-AzADServicePrincipal -ApplicationId "00000003-0000-0000-c000-000000000000"

# Grant Subscription.ReadWrite.All
$role = $graphSP.AppRole | Where-Object { $_.Value -eq "Subscription.ReadWrite.All" }
New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId `
    -ResourceId $graphSP.Id -AppRoleId $role.Id

# Grant Group.Read.All
$role = $graphSP.AppRole | Where-Object { $_.Value -eq "Group.Read.All" }
New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId `
    -ResourceId $graphSP.Id -AppRoleId $role.Id
```

### 4. Deploy the Auto-Renewal Function

Deploy the Function App including the `RenewSubscription` function:

```powershell
func azure functionapp publish groupchangefunction
```

### 5. Optional: Set Environment Variable

For explicit control, add the subscription ID as an environment variable:

```powershell
az functionapp config appsettings set `
    --name groupchangefunction `
    --resource-group groupchangefunction `
    --settings "GRAPH_SUBSCRIPTION_ID=<your-subscription-id>"
```

## Monitoring

### Check Subscription Status

```powershell
.\check-subscription.ps1
```

This shows:
- All active subscriptions
- Expiration times
- Time until expiration
- Warnings for expiring subscriptions

### Manual Renewal

If needed, manually renew a subscription:

```powershell
.\renew-subscription.ps1
```

Or specify a subscription ID:

```powershell
.\renew-subscription.ps1 -SubscriptionId "your-subscription-id"
```

## How It Works

### Subscription Lifecycle

1. **Creation**: `create-api-subscription-topic.ps1` creates a subscription with 3-day expiration
2. **Auto-Renewal**: The `RenewSubscription` function runs every 12 hours and renews subscriptions expiring within 24 hours
3. **Monitoring**: `check-subscription.ps1` helps verify subscription status

### Maximum Expiration

Microsoft Graph subscriptions for `groups` resource have a **maximum expiration of 4230 minutes (~3 days)**. The auto-renewal function ensures subscriptions are renewed before expiration.

### EventGrid Integration

Subscriptions are configured to send notifications to:
```
EventGrid:?azuresubscriptionid={subscription}&resourcegroup={rg}&partnertopic={topic}&location={location}
```

This routes Graph change notifications through Azure EventGrid Partner Topics to your Function App.

## Troubleshooting

### No Events Received

1. **Check subscription status**:
   ```powershell
   .\check-subscription.ps1
   ```

2. **Verify subscription exists and is active**:
   - Should not be expired
   - Should use EventGrid notification URL

3. **Check EventGrid configuration**:
   ```powershell
   az eventgrid partner topic show --name default --resource-group groupchangefunction
   az eventgrid partner topic event-subscription list --partner-topic-name default --resource-group groupchangefunction
   ```

### Subscription Expired

If a subscription expires, recreate it:

```powershell
.\create-api-subscription-topic.ps1
```

### Auto-Renewal Not Working

1. Verify user-assigned managed identity `groupchangefunction-identities-9bef22` is assigned to the Function App
2. Check the managed identity has required Graph permissions:
   ```powershell
   # Check assigned permissions
   $principalId = "e4ad71a2-53c3-467f-a553-bc7eebf711b5"
   Get-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId
   ```
3. Run `.\grant-graph-permissions.ps1` if permissions are missing
4. Check Function App logs for renewal attempts
5. Verify the RenewSubscription function is deployed and enabled

## Security Notes

- `subscription-info.json` contains subscription details and is excluded from git
- The auto-renewal function uses Managed Identity (no credentials stored)
- Subscription IDs should be treated as sensitive information

## References

- [Microsoft Graph Change Notifications](https://learn.microsoft.com/graph/api/resources/webhooks)
- [Azure EventGrid Partner Topics](https://learn.microsoft.com/azure/event-grid/partner-events-overview)
- [Graph Subscription Lifecycle](https://learn.microsoft.com/graph/webhooks-lifecycle)
