# Subscription Ownership Issue - Troubleshooting Guide

## Problem
```
ERROR: [ExtensionError] : Operation: Read; Exception: [Status Code: Unauthorized; Reason: Unauthorized;
Message : Subscription does not belong to application.]
```

## Root Cause

Microsoft Graph subscriptions are **owned by the application** that creates them. In your case:

- **Subscription ID**: `69b82601-c3c8-446f-a72c-2384784cd404`
- **Created by**: Your user account (delegated authentication)
- **Trying to access**: Function App's managed identity `groupchangefunction-identities-9bef22`
- **Result**: ❌ Unauthorized - different applications

## Why This Happens

When you run `create-api-subscription-topic.ps1` **locally**:
1. You authenticate with `Connect-MgGraph` using YOUR user account
2. The subscription is created under a Microsoft application associated with your account
3. This subscription is "owned" by that application

When the **Azure Function** runs:
1. It authenticates using the managed identity
2. It tries to read/renew the subscription
3. Microsoft Graph checks ownership and denies access

## Solutions

### Option 1: Delete and Let Subscription Expire (Easiest)
The subscription will automatically expire in 3 days (max lifetime). Just wait and create a new one later.

```powershell
# No action needed - wait for expiration
# Check expiration date in Azure Portal or with Get-MgSubscription
```

### Option 2: Delete Old Subscription (Recommended)

Delete the old subscription and let the Function App manage its own:

```powershell
cd tools
.\Remove-OldSubscription.ps1
```

If you get an error about ownership, authenticate as the user who created it:
```powershell
Connect-MgGraph -Scopes "Subscription.ReadWrite.All"
Remove-MgSubscription -SubscriptionId "69b82601-c3c8-446f-a72c-2384784cd404"
```

### Option 3: Create Subscription with Managed Identity (Advanced)

This is **difficult locally** because managed identities only work from Azure resources. You have two approaches:

#### A. Use Azure Cloud Shell (Easiest for managed identity)

1. Open Azure Portal → Click **Cloud Shell** icon (top right)
2. Choose PowerShell
3. Install the module:
   ```powershell
   Install-Module Microsoft.Graph.ChangeNotifications -Force
   Install-Module Microsoft.Graph.Authentication -Force
   ```
4. Upload `create-api-subscription-topic.ps1` to Cloud Shell
5. Authenticate with the managed identity:
   ```powershell
   # This only works in Azure Cloud Shell or Azure VMs with the managed identity assigned
   Connect-MgGraph -Identity -ClientId "0ed597a6-5cca-4c6f-b51e-10510010e936"
   ```
6. Run the script:
   ```powershell
   .\create-api-subscription-topic.ps1
   ```

#### B. Use Service Principal with Certificate/Secret (Complex)

Create an App Registration that mirrors the managed identity's permissions:

1. Azure Portal → Entra ID → App registrations → New registration
2. Add API permissions: `Group.Read.All` (Application)
3. Create client secret or certificate
4. Use service principal authentication:
   ```powershell
   $clientSecret = ConvertTo-SecureString "your-secret" -AsPlainText -Force
   $credential = New-Object System.Management.Automation.PSCredential("app-id", $clientSecret)
   Connect-MgGraph -ClientSecretCredential $credential -TenantId "tenant-id"
   ```

### Option 4: Add Code to Function App to Create Subscription

Modify `RenewSubscription` function to create a subscription if none exists:

```powershell
if ($relevantSubscriptions.Count -eq 0) {
    Write-Host "No subscriptions found - creating new one..."

    $params = @{
        changeType = "updated,deleted,created"
        notificationUrl = "EventGrid:?azuresubscriptionid=..."
        resource = "groups"
        expirationDateTime = (Get-Date).AddMinutes(4230)
        clientState = (New-Guid).ToString()
    }

    $newSubscription = New-MgSubscription -BodyParameter $params
    Write-Host "Created new subscription: $($newSubscription.Id)"
}
```

## Verification

After creating a new subscription with the managed identity:

```powershell
# From your local machine - check what YOU can see
Connect-MgGraph -Scopes "Subscription.Read.All"
Get-MgSubscription
```

```powershell
# Check Function App logs to see what IT can see
cd tools
.\Get-FunctionLogs.ps1
```

## Prevention

To avoid this issue in the future:

1. **Document subscription ownership**: Note which identity created each subscription
2. **Use consistent identity**: Always use the same identity for create/renew operations
3. **Add subscription creation to Function**: Make the Function App self-sufficient
4. **Use App Configuration**: Store subscription IDs in Azure App Configuration, accessible by both local dev and Function App

## Key Takeaway

**Managed identities cannot authenticate from local development machines.** You must either:
- Use Azure Cloud Shell with managed identity
- Use a service principal with certificate/secret
- Accept that local and Azure will have separate subscriptions
- Let subscriptions expire and recreate as needed
