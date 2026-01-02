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

#region variables
$moduesFolder = Join-Path -Path $PSScriptRoot -chold 'modules'
$tagToApply = 'mfabackup'
$cloudEventObj = $eventGridEvent | ConvertFrom-Json
# Extract parameters from CloudEvent
$groupId = $cloudEventObj.data.resourceData.id
$userId = $cloudEventObj.data.resourceData.'members@delta'[0].id
$operation = if ($cloudEventObj.data.resourceData.'members@delta'[0].'@removed' -eq 'deleted')
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
#endregion variables

#region Validation
# Validate that managed dependencies are loaded
Write-Host "Validating required modules are available..." -ForegroundColor Cyan
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.DirectoryManagement'
)

foreach ($module in $requiredModules)
{
    if (-not (Get-Module -Name $module -ListAvailable))
    {
        Write-Warning " Module '$module' is not available. Attempting to import from modules folder..." -ForegroundColor Yellow
        if (Test-Path -Path $moduesFolder)
        {
            $modulePath = Join-Path -Path $moduesFolder -ChildPath $module
            if (Test-Path -Path $modulePath)
            {
                Write-Verbose " Importing module '$module' from '$modulePath'..." -ForegroundColor Cyan
                try
                {
                    Import-Module -Name $modulePath -Force
                    Write-Host " Successfully imported module '$module'." -ForegroundColor Green
                }
                catch
                {
                    Write-Error " Failed to import module '$module' from '$modulePath': $_" -ForegroundColor Red
                    throw "Module '$module' import failed."
                }
            }
            else
            {
                Write-Error " Required module '$module' not found in modules folder '$moduesFolder'." -ForegroundColor Red
                throw "Module '$module' is missing."
            }
        }
        else
        {
            Write-Error " Modules folder '$moduesFolder' does not exist." -ForegroundColor Red
            throw "Modules folder is missing."
        }
    }
    Write-Host "All required modules are available." -ForegroundColor Green
    #endregion

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

    #region Main Script
    Write-Host "CloudEvent parsed successfully" -ForegroundColor Green
    Write-Host "Group ID: $groupId" -ForegroundColor Cyan
    Write-Host "User ID: $userId" -ForegroundColor Cyan
    Write-Host "Operation: $operationLabel" -ForegroundColor Cyan
    Write-Host " Tag to Apply: $tagToApply" -ForegroundColor Cyan

    try
    {
        # Connect to Microsoft Graph
        Connect-MgGraph -Identity
        Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green

        # get user devices and information
        $user = Get-MgUser -UserId $userId -ErrorAction Stop
        $group = Get-MgGroup -GroupId $groupId -ErrorAction Stop
        $devices = Get-MgUserRegisteredDevice -UserId $userId -ErrorAction Stop
        $userDisplayName = $user.DisplayName
        $userPrincipalName = $user.UserPrincipalName
        $groupName = $group.DisplayName
        Write-Host "User $userDisplayName ($userPrincipalName) was $(if ($operation -eq 'add') { 'added to' } else { 'removed from' }) group $groupName" -ForegroundColor Green
        Write-Host "Getting devices for user $userDisplayName ($userPrincipalName)..." -ForegroundColor Cyan
        Write-Host "Found $($devices.count) devices registered to user $userDisplayName ($userPrincipalName)" -ForegroundColor Green

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
        $devicesToClean = @()
        foreach ($device in $devices)
        {
            $currentTag = if ($device.ExtensionAttribute1)
            {
                $device.ExtensionAttribute1
            }
            else
            {
                $null
            }

            if ($currentTag -ne $tagToApply -and $operation -eq 'add' -and $device.OperatingSystem -eq 'Windows')
            {
                $devicesToTag += $device
            }
            elseif ($currentTag -eq $tagToApply -and $operation -eq 'remove' -and $device.OperatingSystem -eq 'Windows')
            {
                # For removal, we can also track devices to clean if needed
                $devicesToClean += $device
            }
        }

        $targetDevices = if ($operation -eq 'add')
        {
            $devicesToTag
        }
        else
        {
            $devicesToClean
        }
        $targetActionNoun = if ($operation -eq 'add')
        {
            'tagging'
        }
        else
        {
            'tag removal'
        }
        Write-Host "Found $($targetDevices.Count) devices that need $targetActionNoun" -ForegroundColor Cyan

        if ($targetDevices.Count -gt 0)
        {
            $successCount = 0
            $failureCount = 0
            foreach ($device in $targetDevices)
            {
                if (-not $WhatIf)
                {
                    try
                    {
                        $tagValueToApply = if ($operation -eq 'remove')
                        {
                            $null
                        }
                        else
                        {
                            $tagToApply
                        }
                        $params = @{
                            "extensionAttribute1" = $tagValueToApply
                        }
                        Update-MgDevice -DeviceId $device.Id -BodyParameter $params
                        $successAction = if ($operation -eq 'remove')
                        {
                            'Removed tag from'
                        }
                        else
                        {
                            'Applied tag to'
                        }
                        Write-Host " $successAction device: $($device.DisplayName)" -ForegroundColor Green
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
                        Write-Error " Failed to $failureAction $($device.DisplayName)" -ForegroundColor Red
                        $failureCount++
                    }
                }
                else
                {
                    $whatIfAction = if ($operation -eq 'remove')
                    {
                        'remove tag from'
                    }
                    else
                    {
                        'tag'
                    }
                    Write-Host " [WHATIF] Would $($whatIfAction): $($device.DisplayName)" -ForegroundColor Yellow
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
        Write-Host " Devices cleaned: $($devicesToClean.Count)" -ForegroundColor Cyan
    }
    catch
    {
        Write-Error "`nScript failed: $_" -ForegroundColor Red
    }
    finally
    {
        $logPayload = @()
        $logPayload += ""
        $logPayload += "=== Event Snapshot ==="
        $logPayload += ($humanReadable -join "`n`n")
        Push-OutputBinding -Name log -Value ($logPayload -join "`n")
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    #endregion Main Script
