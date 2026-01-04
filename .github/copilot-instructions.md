# Azure PowerShell Function App - AI Coding Agent Instructions

## Project Overview
PowerShell-based Azure Function App for Microsoft Graph subscription management and Entra ID device synchronization. Uses event-driven architecture with EventGrid triggers and timer-based auto-renewal.

## Architecture & Components

### Core Functions
- **EventGridTrigger1** - Bidirectional device tag sync between user/device groups in Entra ID
- **RenewSubscription** - Timer-triggered (12h) Graph subscription auto-renewal with managed identity auth
- Both functions accept CloudEvents v1.0 format and use Microsoft.Graph.* SDK modules

### Module Management (Critical)
**Flex Consumption Plan Auto-loading**: Modules in `modules/` are automatically loaded by PowerShell worker. DO NOT manually import in `profile.ps1` or function code unless testing locally.

Required modules (locally stored, NOT in `requirements.psd1`):
```powershell
Microsoft.Graph.Authentication (2.34.0)
Microsoft.Graph.Groups (2.34.0)
Microsoft.Graph.Users (2.34.0)
Microsoft.Graph.Identity.DirectoryManagement (2.34.0)
Microsoft.Graph.ChangeNotifications (2.30.0, 2.34.0)
```

### Authentication Pattern
Always use managed identity for Azure resources:
```powershell
Connect-MgGraph -Identity -NoWelcome
```
User-assigned managed identity: `groupchangefunction-identities-9bef22` (Client ID: `0ed597a6-5cca-4c6f-b51e-10510010e936`)

## Development Workflows

### Local Testing
```powershell
# Start Azurite for local storage emulation (run in background)
azurite --silent --location . --debug ./azurite.log

# Start Functions host
func start

# Test specific function with HTTP file
# See EventGridTrigger1/test-events.http for CloudEvents examples
```

### Running Tests
```powershell
# Interactive test file selection with paging
.\Invoke-PesterTests.ps1 -TestFile "Interactive"

# Run specific test type
.\Invoke-PesterTests.ps1 -TestType Unit -OutputVerbosity Normal

# Interactive tag selection
.\Invoke-PesterTests.ps1 -Tags "Interactive"

# Exclude slow tests
.\Invoke-PesterTests.ps1 -Tags "Slow" -Exclude
```

**Test Configuration**: `PesterConfiguration.ps1` centralizes Pester 5.x settings
**Verbosity Control**: Tests suppress warnings unless `-OutputVerbosity Detailed` set in `Invoke-PesterTests.ps1`

### Graph Subscription Management
```powershell
# Create new subscription (3-day expiration)
.\tools\create-api-subscription-topic.ps1

# Grant permissions to managed identity (requires Global Admin)
.\tools\grant-graph-permissions.ps1

# Check subscription status
.\tools\check-subscription.ps1

# Manual renewal
.\tools\renew-subscription.ps1
```

## Project-Specific Conventions

### Logging Pattern
All functions use structured diagnostic logging to queue storage:
```powershell
$diagnosticLog = @()
$diagnosticLog += "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Message"
# ... function logic ...
Push-OutputBinding -Name log -Value ($diagnosticLog -join "`n")
```

### Event Processing
Functions log received events before processing:
```powershell
$events = if ($eventGridEvent -is [System.Array]) { $eventGridEvent } else { @($eventGridEvent) }
$humanReadable = foreach ($evt in $events) {
    # Extract: id, eventType/type, subject, eventTime/time, data
}
Push-OutputBinding -Name log -Value ($humanReadable -join "`n`n")
```

### Error Handling
- Set `$ErrorActionPreference = "Stop"` at function start
- Use detailed diagnostic logging with timestamps
- Log Graph API errors with context for manual intervention
- Timer functions: Continue on error, log failures for review

### Configuration Files
- **host.json** - Trace-level logging for dev, Application Insights sampling enabled
- **local.settings.json** - Managed identity config for local dev (uses clientId for auth)
- **subscription-info.json** - Created by `create-api-subscription-topic.ps1`, stores subscription metadata

## Key Integration Points

### Microsoft Graph API
- Subscriptions expire in 4230 minutes (3 days max)
- RenewSubscription checks if expiration < 24 hours
- Falls back to querying all subscriptions if GRAPH_SUBSCRIPTION_ID not set
- Resource: `groups`, NotificationUrl uses EventGrid

### Azure Storage
- Local: Azurite (`UseDevelopmentStorage=true`)
- Production: Managed identity with `__credential=managedidentity` suffix pattern
- Queue bindings for diagnostic logs

### Application Insights
- Connection string in local.settings.json
- Automatic telemetry for function executions
- Use `Get-FunctionLogs.ps1` to query historical logs

## Testing & Quality

### Test Organization
- **tests/Unit/** - PSScriptAnalyzer syntax validation, encoding checks
- Test discovery finds `*.Tests.ps1` files
- Tags: `Unit`, `Fast`, `Discovery`, `Syntax`, `Encoding`, `PSScriptAnalyzer`

### Pester Best Practices
- Use `BeforeAll` for module imports and setup
- Store reusable variables in `$script:` scope
- Tag tests appropriately for filtering
- Conditional verbosity via `$PesterPreference.Output.Verbosity.Value`

## Documentation References
- **SUBSCRIPTION-MANAGEMENT.md** - Complete Graph subscription workflows
- **.github/chatmodes/Azure_function_codegen_and_deployment.chatmode.md** - Deployment patterns and enterprise guidelines
- Function inline help blocks (Synopsis/Description/Notes) document purpose and dependencies

## Common Gotchas
1. **Module Import**: Never manually import in Flex Consumption - auto-loaded from modules/ folder
2. **Subscription Expiration**: Graph subscriptions have 3-day max, auto-renewal runs every 12h
3. **Managed Identity**: Must grant Graph API permissions separately via `grant-graph-permissions.ps1`
4. **Local Testing**: Azurite must be running for storage bindings
5. **Test Verbosity**: Default mode suppresses warnings; use `Detailed` for troubleshooting
