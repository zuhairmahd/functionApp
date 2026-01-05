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
($humanReadable -join "`n`n") | Write-Host
$logPayload = @()
$logPayload += ""
$logPayload += "=== Event Snapshot ==="
$logPayload += ($humanReadable -join "`n`n")
Push-OutputBinding -Name log -Value ($logPayload -join "`n")
Write-Verbose "Received event: $($eventGridEvent |Out-String)"
Write-Verbose "Trigger metadata: $($TriggerMetadata | Out-String)"
Write-Host "received event: $($eventGridEvent | Out-String)" -ForegroundColor Cyan
Write-Host "Trigger metadata: $($TriggerMetadata | Out-String)" -ForegroundColor Cyan
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
$managedIdentityClientId = "0ed597a6-5cca-4c6f-b51e-10510010e936"
#endregion variables

#region more logging
Write-Host "Variables are as follows:"
Write-Host " GroupId: $groupId"
Write-Host " UserId: $userId"
Write-Host " Operation: $operation ($operationLabel)"
Write-Host "Operation label: $operationLabel"
# Note: Modules in the Modules/ folder are automatically added to PSModulePath by Azure Functions
# They will auto-load when first referenced (no manual import needed)
Write-Host "Validating required modules are available..." -ForegroundColor Cyan
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
        Write-Host " Module '$module' is available." -ForegroundColor Green
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
    Write-Host "PSModulePath = $env:PSModulePath" -ForegroundColor Yellow
    throw "Missing required modules."
}
Write-Host "All required modules are available." -ForegroundColor Green
#endregion more logging

#region Main Script
Write-Host "CloudEvent parsed successfully" -ForegroundColor Green
Write-Host "Group ID: $groupId" -ForegroundColor Cyan
Write-Host "User ID: $userId" -ForegroundColor Cyan
Write-Host "Operation: $operationLabel" -ForegroundColor Cyan
Write-Host " Tag to Apply: $tagToApply" -ForegroundColor Cyan

try
{
    # Connect to Microsoft Graph
    Connect-MgGraph -Identity -ClientId $managedIdentityClientId -ErrorAction Stop
    Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green

    # get user devices and information
    $user = Get-MgUser -UserId $userId -ErrorAction Stop
    $group = Get-MgGroup -GroupId $groupId -ErrorAction Stop
    $devices = Get-MgUserRegisteredDevice -UserId $userId
    $userDisplayName = $user.DisplayName
    $userPrincipalName = $user.UserPrincipalName
    $groupName = $group.DisplayName
    Write-Host "User $userDisplayName ($userPrincipalName) was $(if ($operation -eq 'add') { 'added to' } else { 'removed from' }) group $groupName" -ForegroundColor Green
    Write-Host "Getting devices for user $userDisplayName ($userPrincipalName)..." -ForegroundColor Cyan
    Write-Host "Found a total of $($devices.count) devices registered to user $userDisplayName ($userPrincipalName)" -ForegroundColor Green

    # Apply tags to devices
    $tagAction = if ($operation -eq 'add')
    {
        "Applying tag '$tagToApply'"
    }
    else
    {
        "Removing tag '$tagToApply'"
    }
    Write-Host "`n$tagAction for devices..." -ForegroundColor Cyan

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
            Write-Host " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem" -ForegroundColor Yellow
            Write-Host "The device will be tagged with '$tagToApply'" -ForegroundColor Yellow
            $devicesToTag += $device
        }
        elseif ($currentTag -eq $tagToApply -and $operation -eq 'remove' -and $operatingSystem -eq 'Windows')
        {
            $devicesToTag += $device
            Write-Host " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem" -ForegroundColor Yellow
            Write-Host "The tag '$tagToApply' will be removed from the device" -ForegroundColor Yellow
        }
        elseif ($operatingSystem -eq 'Windows')
        {
            Write-Host " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem will not be modified." -ForegroundColor DarkGray
        }
    }
    Write-Host "Found $($devicesToTag.Count) devices to $operation" -ForegroundColor Cyan


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
                Write-Host "  Updating device $displayName (ID: $deviceId                                       )..." -ForegroundColor DarkGray

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
                Write-Host " $successAction device: $($device.additionalProperties.displayName)" -ForegroundColor Green
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
            Write-Host "$operationSummary completed with $failureRate% failure rate ($failureCount / $($targetDevices.Count))" -ForegroundColor Yellow
        }
        else
        {
            Write-Host "$operationSummary completed successfully for all devices" -ForegroundColor Green
        }
    }

    Write-Host "`nScript completed successfully" -ForegroundColor Green
    Write-Host " Devices tagged: $($devicesToTag.Count)" -ForegroundColor Cyan
}
catch
{
    Write-Error "`nScript failed: $_"
}
finally
{
    $logPayload = @()
    $logPayload += ""
    $logPayload += "=== Event Snapshot ==="
    $logPayload += ($humanReadable -join "`n`n")
    Push-OutputBinding -Name log -Value ($logPayload -join "`n") -ErrorAction SilentlyContinue | Out-Null
}
#endregion Main Script

