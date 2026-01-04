[CmdletBinding()]
param([switch]$whatIf)
$userId = "c2fb973c-099e-4ab6-bef4-aad5a7b915fc"
$operation = "add"
$tagToApply = 'mfabackup'
try
{
    # Connect to Microsoft Graph
    Connect-MgGraph -NoWelcome
    Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green

    # get user devices and information
    $user = Get-MgUser -UserId $userId -ErrorAction Stop
    $registeredDevices = Get-MgUserRegisteredDevice -UserId $userId
    $userDisplayName = $user.DisplayName
    $userPrincipalName = $user.UserPrincipalName
    Write-Host "User $userDisplayName ($userPrincipalName) was $(if ($operation -eq 'add') { 'added to' } else { 'removed from' }) group $groupName" -ForegroundColor Green
    Write-Host "Getting devices for user $userDisplayName ($userPrincipalName)..." -ForegroundColor Cyan

    # Get full device objects with extension attributes (Windows devices only)
    $devices = @()
    foreach ($regDevice in $registeredDevices)
    {
        # Check if this is a Windows device before fetching full details
        $osType = if ($regDevice.OperatingSystem)
        {
            $regDevice.OperatingSystem
        }
        else
        {
            $regDevice.AdditionalProperties.operatingSystem
        }

        # Skip non-Windows devices to reduce API calls
        if ($osType -ne 'Windows')
        {
            Write-Host "  Skipping non-Windows device: $($regDevice.AdditionalProperties.displayName) (OS: $osType)" -ForegroundColor DarkGray
            continue
        }

        $deviceId = if ($regDevice.Id)
        {
            $regDevice.Id
        }
        else
        {
            $regDevice.AdditionalProperties.id
        }
        try
        {
            $fullDevice = Get-MgDevice -DeviceId $deviceId -ErrorAction Stop
            Write-Host "  Retrieved Windows device: $($fullDevice.DisplayName) (ID: $($fullDevice.Id))" -ForegroundColor DarkGray
            $devices += $fullDevice
        }
        catch
        {
            Write-Warning "Could not retrieve device $deviceId : $_"
        }
    }
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
        # Get device properties - now directly available from full device object
        $displayName = $device.DisplayName
        $operatingSystem = $device.OperatingSystem
        $extensionAttr = $device.AdditionalProperties.extensionAttributes.extensionAttribute1
        $deviceId = $device.Id

        $currentTag = if ($extensionAttr)
        {
            $extensionAttr
        }
        else
        {
            "No tag"
        }

        Write-Host " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem" -ForegroundColor Yellow

        if ($currentTag -ne $tagToApply -and $operation -eq 'add' -and $operatingSystem -eq 'Windows')
        {
            $devicesToTag += $device
        }
        elseif ($currentTag -eq $tagToApply -and $operation -eq 'remove' -and $operatingSystem -eq 'Windows')
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

                    Write-Host "  Updating device $($device.DisplayName) (ID: $($device.Id))..." -ForegroundColor DarkGray

                    $params = @{
                        "extensionAttributes" = @{
                            "extensionAttribute1" = $tagValueToApply
                        }
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
                    Write-Error " Failed to $failureAction $($device.DisplayName)"
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
    Write-Error "`nScript failed: $_"
}
