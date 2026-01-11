<#PSScriptInfo
.VERSION 2.0.0
.GUID 8f3a2d1c-9e4b-4a7f-b2c3-5d6e8f9a1b2c
.AUTHOR Zuhair Mahmoud
.DESCRIPTION Synchronizes device tags between user groups and device groups in Entra ID using Microsoft Graph PowerShell SDK
.EXTERNALMODULEDEPENDENCIES Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
.SYNOPSIS
Manages device tags by syncing user group membership with device registration status in Entra ID, accepting CloudEvents v1.0 format input.

.DESCRIPTION
This script performs bidirectional synchronization of device tags in Entra ID:
1. Accepts CloudEvents v1.0 format input for directory update events
2. Retrieves all users from a specified user group
3. Identifies Entra-joined Windows devices registered to those users
4. Applies a specified tag to eligible devices
5. Validates devices in a device group and removes tags from devices whose owners are not in the user group

The script uses Microsoft Graph PowerShell SDK for all Graph API interactions and includes comprehensive logging.

.PARAMETER eventGridEvent
A JSON string or file path containing a CloudEvents v1.0 format event for directory update.

.PARAMETER TriggerMetadata
Metadata about the trigger event (automatically provided by Azure Functions).

.PARAMETER WhatIf
A switch to perform a dry-run of the script without making actual changes.
When enabled, the script will show what actions would be taken without modifying any devices.
Default: $false

.EXAMPLE
.\DeviceDirSync.ps1 -CloudEvent '{"specversion":"1.0","type":"com.microsoft.directory.device.update","source":"/tenants/contoso","id":"123","time":"2025-12-27T07:00:00Z","data":{"userGroupId":"275105b8-ef99-4ca6-bbca-2fec2d0f4699","deviceGroupId":"e6aa9d01-3127-4a3b-9027-046d5acdfe72","tagToApply":"backupMFA"}}'
Processes a CloudEvent to sync device tags between the specified user and device groups.

.NOTES
  - Logs are written to: .\logs\DeviceDirSync.log
  - Supports both standard and CMTrace log formats
  - Thread-safe logging with mutex protection
  - Automatic log rotation when size exceeds 10MB
#>
[CmdletBinding()]
param($eventGridEvent, $TriggerMetadata)

#region log received event
$events = if ($eventGridEvent -is [System.Array])
{
    $eventGridEvent
}
else
{
    @($eventGridEvent)
}
$humanReadable = foreach ($evt in $events)
{
    $lines = @()
    $lines += "Id: $($evt.id)"
    $evtType = $evt.eventType
    if (-not $evtType)
    {
        $evtType = $evt.type
    }
    $lines += "EventType: $evtType"
    $lines += "Subject: $($evt.subject)"
    $evtTime = $evt.eventTime
    if (-not $evtTime)
    {
        $evtTime = $evt.time
    }
    $lines += "EventTime: $evtTime"
    $lines += "DataVersion: $($evt.dataVersion)"
    $lines += "MetadataVersion: $($evt.metadataVersion)"
    $lines += "Data:"
    $lines += ($evt.data | ConvertTo-Json -Depth 8 -Compress)
    $lines -join "`n"
}
# Still log to console for quick local verification
($humanReadable -join "`n`n") | Write-Output
$logPayload = @()
$logPayload += ""
$logPayload += "=== Event Snapshot ==="
$logPayload += ($humanReadable -join "`n`n")
Push-OutputBinding -Name log -Value ($logPayload -join "`n")
Write-Verbose "Received event: $($eventGridEvent |Out-String)"
Write-Verbose "Trigger metadata: $($TriggerMetadata | Out-String)"
Write-Output "received event: $($eventGridEvent | Out-String)"
Write-Output "Trigger metadata: $($TriggerMetadata | Out-String)"
#endregion log received event

#region variables
$tagToApply = 'mfabackup'
$cloudEventObj = if ($eventGridEvent -is [string])
{
    try
    {
        $eventGridEvent | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        Write-Error "Failed to parse eventGridEvent as JSON: $_"
        throw
    }
}
else
{
    $eventGridEvent
}
if ($cloudEventObj)
{
    # Extract parameters from CloudEvent
    $groupId = $cloudEventObj.data.resourceData.id
    $userId = if ($null -ne $cloudEventObj.data.resourceData.'members@delta')
    {
        $cloudEventObj.data.resourceData.'members@delta'[0].id
    }
    else
    {
        $null
    }
    $operation = if ($null -ne $cloudEventObj.data.resourceData.'members@delta' -and $cloudEventObj.data.resourceData.'members@delta'[0].'@removed' -eq 'deleted')
    {
        'remove'
    }
    else
    {
        'add'
    }
    $operationLabel = if ($operation -eq 'add')
    {
        'add (apply tag)'
    }
    else
    {
        'remove (clear tag)'
    }
}
else
{
    Write-Error "CloudEvent object is null or invalid."
    throw "CloudEvent object is null or invalid."
}
$managedIdentityClientId = $env:AZURE_CLIENT_ID
#endregion variables

#region more logging
Write-Output "Variables are as follows:"
Write-Output " GroupId: $groupId"
Write-Output " UserId: $userId"
Write-Output " Operation: $operation ($operationLabel)"
Write-Output "Operation label: $operationLabel"
# Note: Modules in the Modules/ folder are automatically added to PSModulePath by Azure Functions
# They will auto-load when first referenced (no manual import needed)
Write-Output "Validating required modules are available..."
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.DirectoryManagement'
)
$allModulesAvailable = $true
foreach ($module in $requiredModules)
{
    # Check if module is available (either loaded or can be auto-loaded)
    if (Get-Module -Name $module -ListAvailable -ErrorAction SilentlyContinue)
    {
        Write-Output " Module '$module' is available."
    }
    else
    {
        Write-Error " Module '$module' is not available in PSModulePath"
        $allModulesAvailable = $false
    }
}

if (-not $allModulesAvailable)
{
    Write-Error "One or more required modules are not available. Check deployment package."
    Write-Output "PSModulePath = $env:PSModulePath"
    throw "Missing required modules."
}
Write-Output "All required modules are available."
#endregion more logging

#region Main Script
Write-Output "CloudEvent parsed successfully"
Write-Output "Group ID: $groupId"
Write-Output "User ID: $userId"
Write-Output "Operation: $operationLabel"
Write-Output " Tag to Apply: $tagToApply"

try
{
    # Connect to Microsoft Graph
    Connect-MgGraph -Identity -ClientId $managedIdentityClientId -ErrorAction Stop
    Write-Output "Successfully connected to Microsoft Graph"

    # get user devices and information
    $user = Get-MgUser -UserId $userId -ErrorAction Stop
    $group = Get-MgGroup -GroupId $groupId -ErrorAction Stop
    $devices = Get-MgUserRegisteredDevice -UserId $userId
    $userDisplayName = $user.DisplayName
    $userPrincipalName = $user.UserPrincipalName
    $groupName = $group.DisplayName
    Write-Output "User $userDisplayName ($userPrincipalName) was $(if ($operation -eq 'add') { 'added to' } else { 'removed from' }) group $groupName"
    Write-Output "Getting devices for user $userDisplayName ($userPrincipalName)..."
    Write-Output "Found a total of $($devices.count) devices registered to user $userDisplayName ($userPrincipalName)"

    # Apply tags to devices
    $tagAction = if ($operation -eq 'add')
    {
        "Applying tag '$tagToApply'"
    }
    else
    {
        "Removing tag '$tagToApply'"
    }
    Write-Output "`n$tagAction for devices..."

    $devicesToTag = @()
    foreach ($device in $devices)
    {
        # Get device properties - now directly available from full device object
        $displayName = $device.additionalProperties.displayName
        $operatingSystem = $device.additionalProperties.operatingSystem
        $extensionAttr = $device.additionalProperties.extensionAttributes.extensionAttribute1
        $deviceId = $device.additionalProperties.id

        $currentTag = if ($extensionAttr)
        {
            $extensionAttr
        }
        else
        {
            "No tag"
        }

        Write-Verbose " Evaluating device: $displayName, Current Tag: $currentTag, OS: $operatingSystem"

        if ($currentTag -ne $tagToApply -and $operation -eq 'add' -and $operatingSystem -eq 'Windows')
        {
            Write-Output " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem"
            Write-Output "The device will be tagged with '$tagToApply'"
            $devicesToTag += $device
        }
        elseif ($currentTag -eq $tagToApply -and $operation -eq 'remove' -and $operatingSystem -eq 'Windows')
        {
            $devicesToTag += $device
            Write-Output " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem"
            Write-Output "The tag '$tagToApply' will be removed from the device"
        }
        elseif ($operatingSystem -eq 'Windows')
        {
            Write-Output " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem will not be modified."
        }
    }
    Write-Output "Found $($devicesToTag.Count) devices to $operation"

    if ($devicesToTag.Count -gt 0)
    {
        $successCount = 0
        $failureCount = 0
        foreach ($device in $devicesToTag                           )
        {
            try
            {
                $tagValueToApply = if ($operation -eq 'remove')
                {
                    ""
                }
                else
                {
                    $tagToApply
                }
                $deviceId = $device.Id
                $displayName = $device.additionalProperties.displayName
                Write-Output "  Updating device $displayName (ID: $deviceId                                       )..."

                $params = @{
                    "extensionAttributes" = @{
                        "extensionAttribute1" = $tagValueToApply
                    }
                }
                Update-MgDevice -DeviceId $deviceId -BodyParameter $params
                $successAction = if ($operation -eq 'remove')
                {
                    'Removed tag from'
                }
                else
                {
                    'Applied tag to'
                }
                Write-Output " $successAction device: $($device.additionalProperties.displayName)"
                $successCount++
            }
            catch
            {
                $failureAction = if ($operation -eq 'remove')
                {
                    'remove tag from'
                }
                else
                {
                    'tag device'
                }
                Write-Error " Failed to $failureAction $($device.additionalProperties.displayName)"
                $failureCount++
            }

        }

        $operationSummary = if ($operation -eq 'remove')
        {
            'Tag removal operation'
        }
        else
        {
            'Tag application operation'
        }
        if ($failureCount -gt 0)
        {
            $failureRate = [math]::Round(($failureCount / $targetDevices.Count) * 100, 2)
            Write-Output "$operationSummary completed with $failureRate% failure rate ($failureCount / $($targetDevices.Count))"
        }
        else
        {
            Write-Output "$operationSummary completed successfully for all devices"
        }
    }

    Write-Output "`nScript completed successfully"
    Write-Output " Devices tagged: $($devicesToTag.Count)"
}
catch
{
    Write-Error "`nScript failed: $_"
}
finally
{
    Disconnect-MgGraph
    Write-Output "Disconnected from Microsoft Graph"
    Write-Output "Writing event info to storage blob"
    $logPayload = @()
    $logPayload += ""
    $logPayload += "=== Event Snapshot ==="
    $logPayload += ($humanReadable -join "`n`n")
    Push-OutputBinding -Name log -Value ($logPayload -join "`n") -ErrorAction SilentlyContinue | Out-Null
    Write-Output "Event info written to storage blob"
}
#endregion Main Script

Write-Output "Function execution completed."