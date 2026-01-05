[CmdletBinding()]
param(
    [switch]$whatIf,
    [ValidateSet("add", "remove")   ]
    [string]$Operation = "add"
)
$userId = "c2fb973c-099e-4ab6-bef4-aad5a7b915fc"
$tagToApply = 'mfabackup'
try
{
    # Connect to Microsoft Graph
    Connect-MgGraph -NoWelcome
    Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green

    # get user devices and information
    $user = Get-MgUser -UserId $userId -ErrorAction Stop
    $devices = Get-MgUserRegisteredDevice -UserId $userId
    $userDisplayName = $user.DisplayName
    $userPrincipalName = $user.UserPrincipalName
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
            # For removal, we can also track devices to clean if needed
            $devicesToClean += $device
            Write-Host " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem" -ForegroundColor Yellow
            Write-Host "The tag '$tagToApply' will be removed from the device" -ForegroundColor Yellow
        }
        elseif ($operatingSystem -eq 'Windows')
        {
            Write-Host " Device: $displayName, Current Tag: $currentTag, OS: $operatingSystem will not be modified." -ForegroundColor DarkGray
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
                Write-Host " [WHATIF] Would $($whatIfAction): $($device.additionalProperties.displayName)" -ForegroundColor Yellow
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
