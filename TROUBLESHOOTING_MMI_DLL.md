# Troubleshooting: Microsoft.Management.Infrastructure DLL Missing

## Problem
Azure Functions PowerShell Worker fails to start with error:
```
System.IO.FileNotFoundException: Could not load file or assembly 'Microsoft.Management.Infrastructure, Version=1.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35'
```

## Root Cause
The error occurs during PowerShell Worker initialization (`InitialSessionState.CreateDefault()`), **before** any user code (including profile.ps1) executes. The DLL is required by PowerShell Core but not found in the worker's assembly search paths.

## Solutions (In Order of Preference)

### Solution 1: Reinstall PowerShell 7 (RECOMMENDED)
The DLL should be part of the PowerShell installation. Reinstall to ensure all components are present:

```powershell
# Run as Administrator
winget install --id Microsoft.PowerShell --source winget --force
```

Or download manually from: https://github.com/PowerShell/PowerShell/releases

After reinstalling, restart your system and try again.

### Solution 2: Copy DLL to .NET Runtime Directory
If reinstalling doesn't help, manually copy the DLL (requires Administrator privileges):

```powershell
# Run as Administrator
$sourceDLL = "C:\Program Files\PowerShell\7\Microsoft.Management.Infrastructure.dll"
$targetPath = "C:\Program Files\dotnet\shared\Microsoft.NETCore.App\8.0.22"  # Adjust version

Copy-Item $sourceDLL -Destination $targetPath -Force
```

### Solution 3: Use Windows PowerShell 5.1 Instead
Temporarily switch to Windows PowerShell 5.1 which has better WMI support:

**local.settings.json:**
```json
{
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "powershell",
    "FUNCTIONS_WORKER_RUNTIME_VERSION": "~5.1",
    ...
  }
}
```

### Solution 4: Remove Microsoft.Graph Dependencies
If Microsoft.Graph modules are causing the issue, consider alternatives:

#### Option A: Use Azure CLI
```powershell
# Install Azure CLI
az login --identity  # In Azure
az ad user list --filter "memberOf eq '{group-id}'"
```

#### Option B: Use REST API with Managed Identity
```powershell
# Get access token
$response = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://graph.microsoft.com/' `
    -Method GET -Headers @{Metadata = "true"}
$token = $response.access_token

# Call Microsoft Graph
$headers = @{
    Authorization = "Bearer $token"
    'Content-Type' = 'application/json'
}
$users = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members" `
    -Headers $headers -Method GET
```

## Changes Made
1. **host.json**: Disabled managed dependencies
   ```json
   "managedDependency": {
     "enabled": false
   }
   ```

2. **requirements.psd1**: Commented out Microsoft.Graph modules

3. **profile.ps1**: Added manual module loading logic

4. **bin/**: Created bin directory with Microsoft.Management.Infrastructure.dll

## Testing
After applying a solution:

```powershell
# Stop all function processes
Get-Process func, dotnet -ErrorAction SilentlyContinue | Stop-Process -Force

# Start fresh
func start
```

## For Production Deployment
When deploying to Azure:
1. The managed identity will automatically handle authentication
2. PowerShell 7.2 is the recommended runtime version
3. Ensure Application Settings include:
   ```
   FUNCTIONS_WORKER_RUNTIME_VERSION = 7.2
   ```

## Additional Resources
- [Azure Functions PowerShell developer guide](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell)
- [PowerShell in Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell#powershell-versions)
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/overview)
