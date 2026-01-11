<#
.SYNOPSIS
    Removes Microsoft Graph subscriptions interactively or in batch.

.DESCRIPTION
    This script provides multiple methods to remove Microsoft Graph subscriptions:
    - Interactive menu: Select one or more subscriptions from a numbered list
    - Single deletion: Specify a subscription ID directly
    - Batch deletion: Remove all subscriptions at once

    The script requires Subscription.ReadWrite.All permissions and connects to
    Microsoft Graph using delegated authentication. It's useful for cleaning up
    subscriptions that were created by different identities or applications.

.PARAMETER graphSubscriptionId
    The specific subscription ID to remove. If not provided and -All is not specified,
    displays an interactive menu of all available subscriptions.

.PARAMETER All
    Switch to remove all subscriptions in the tenant. Always requires confirmation
    unless -Confirm is explicitly set to $false.

.PARAMETER NoConfirm
    Switch to skip all confirmation prompts for fully non-interactive operation.
    Default is $false (interactive mode with confirmations).

    CAUTION: Using -NoConfirm will skip all safety prompts.

.EXAMPLE
    .\Remove-OldSubscription.ps1

    Displays an interactive menu showing all subscriptions with their details.
    Allows you to select one or more subscriptions by number (e.g., "1,3,5").

.EXAMPLE
    .\Remove-OldSubscription.ps1 -graphSubscriptionId "69b82601-c3c8-446f-a72c-2384784cd404"

    Removes the specified subscription after confirmation. Displays subscription
    details before deletion.

.EXAMPLE
    .\Remove-OldSubscription.ps1 -All

    Removes all subscriptions in the tenant after displaying a list and
    requesting confirmation.

.EXAMPLE
    .\Remove-OldSubscription.ps1 -All -NoConfirm

    Removes all subscriptions without any confirmation prompts. Use with extreme
    caution - this is intended for automation scenarios.

.EXAMPLE
    .\Remove-OldSubscription.ps1 -NoConfirm

    Shows the interactive menu but skips confirmation when deleting the selected
    subscriptions.

.NOTES
    File Name      : Remove-OldSubscription.ps1
    Author         : Azure Function Development Team
    Prerequisite   : Microsoft.Graph.ChangeNotifications module
                     Microsoft.Graph.Authentication module

    Requirements:
    - You must be authenticated as a user with Subscription.ReadWrite.All permission
    - For subscriptions created by different applications, you may see ownership errors
    - Subscriptions have a maximum lifetime of 3 days and auto-expire if not renewed

    Common Use Cases:
    - Cleaning up test subscriptions during development
    - Removing subscriptions created by delegated auth before switching to managed identity
    - Resolving subscription ownership conflicts
    - Batch cleanup of expired or orphaned subscriptions

.LINK
    https://learn.microsoft.com/graph/api/subscription-delete

.LINK
    https://learn.microsoft.com/graph/webhooks
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Single', Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$graphSubscriptionId,

    [Parameter(ParameterSetName = 'All', Mandatory = $true)]
    [switch]$All,

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'All')]
    [switch]$NoConfirm
)

#Requires -Modules Microsoft.Graph.ChangeNotifications, Microsoft.Graph.Authentication

# Set strict mode for better error detection
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper Functions
function Write-Banner()
{
    <#
    .SYNOPSIS
        Displays a formatted banner message.
    #>
    param(
        [string]$Message,
        [string]$Color = 'Cyan'
    )

    Write-Host "============================================" -ForegroundColor $Color
    Write-Host $Message -ForegroundColor $Color
    Write-Host "============================================`n" -ForegroundColor $Color
}

function Connect-GraphIfNeeded()
{
    <#
    .SYNOPSIS
        Ensures connection to Microsoft Graph with required permissions.
    #>
    [CmdletBinding()]
    param(
        [switch]$showScopes
    )
    $context = Get-MgContext

    if (-not $context)
    {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes "Subscription.ReadWrite.All" -NoWelcome
        Write-Host "Connected successfully.`n" -ForegroundColor Green
    }
    else
    {
        Write-Host "Already connected to Microsoft Graph" -ForegroundColor Green
        Write-Host "Account: $($context.Account)" -ForegroundColor Gray
        if ($showScopes)
        {
            Write-Host "Scopes: $($context.Scopes -join ', ')`n" -ForegroundColor Gray
        }
    }
}

function Get-AllGraphEventgridSubscriptions()
{
    <#
    .SYNOPSIS
        Retrieves all Microsoft Graph event grid            subscriptions.
    #>
    try
    {
        Write-Host "Fetching all Eventgrid subscriptions..." -ForegroundColor Cyan
        $subscriptions = Get-MgSubscription -ErrorAction Stop | Where-Object { $_.NotificationUrl -like "*EventGrid*" }

        if (-not $subscriptions -or $subscriptions.Count -eq 0)
        {
            Write-Host "No subscriptions found in this tenant." -ForegroundColor Yellow
            return $null
        }

        Write-Host "Found $($subscriptions.Count) subscription(s).`n" -ForegroundColor Green
        return $subscriptions
    }
    catch
    {
        Write-Host "ERROR: Failed to retrieve subscriptions." -ForegroundColor Red
        Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Show-SubscriptionDetails()
{
    <#
    .SYNOPSIS
        Displays formatted details for a subscription.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Subscription,

        [int]$Index = -1
    )

    if ($Index -ge 0)
    {
        Write-Host "[$($Index + 1)]" -ForegroundColor Cyan -NoNewline
        Write-Host " Subscription ID: $($Subscription.Id)" -ForegroundColor White
    }
    else
    {
        Write-Host "Subscription ID: $($Subscription.Id)" -ForegroundColor Cyan
    }

    Write-Host "    Resource: $($Subscription.Resource)" -ForegroundColor Gray
    Write-Host "    Change Types: $($Subscription.ChangeType)" -ForegroundColor Gray
    Write-Host "    Expiration: $($Subscription.ExpirationDateTime)" -ForegroundColor Gray
    Write-Host "    Application ID: $($Subscription.ApplicationId)" -ForegroundColor Gray
    Write-Host "    Notification URL: $($Subscription.NotificationUrl)" -ForegroundColor DarkGray
    Write-Host ""
}

function Remove-GraphSubscriptions()
{
    <#
    .SYNOPSIS
        Deletes one or more Graph subscriptions with optional confirmation.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Subscriptions,

        [Parameter()]
        [bool]$SkipConfirm = $false
    )

    # Show what will be deleted
    if (-not $SkipConfirm)
    {
        Write-Host "`nYou are about to delete $($Subscriptions.Count) subscription(s):" -ForegroundColor Yellow
        Write-Host ""

        foreach ($sub in $Subscriptions)
        {
            Write-Host "  * " -ForegroundColor Yellow -NoNewline
            Write-Host "$($sub.Id)" -ForegroundColor White
            Write-Host "    Resource: $($sub.Resource) | Expires: $($sub.ExpirationDateTime)" -ForegroundColor Gray
        }

        Write-Host ""
        $confirmResponse = Read-Host "Are you sure you want to DELETE these subscription(s)? (y/N)"
        if ($confirmResponse -ne 'y' -and $confirmResponse -ne 'Y')
        {
            Write-Host "`nOperation cancelled by user." -ForegroundColor Gray
            return
        }
    }

    # Perform deletion
    Write-Host "`nDeleting subscriptions..." -ForegroundColor Cyan
    Write-Host ""

    $successCount = 0
    $failCount = 0
    $errors = @()

    foreach ($sub in $Subscriptions)
    {
        try
        {
            Write-Host "  Deleting $($sub.Id)... " -ForegroundColor Cyan -NoNewline
            Remove-MgSubscription -SubscriptionId $sub.Id -ErrorAction Stop
            Write-Host "SUCCESS" -ForegroundColor Green
            $successCount++
        }
        catch
        {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
            $failCount++
            $errors += [PSCustomObject]@{
                SubscriptionId = $sub.Id
                Error          = $_.Exception.Message
            }
        }
    }

    # Summary
    Write-Host ""
    Write-Banner -Message "Deletion Summary" -Color Cyan
    Write-Host "Total subscriptions: $($Subscriptions.Count)" -ForegroundColor White
    Write-Host "Successfully deleted: $successCount" -ForegroundColor Green

    if ($failCount -gt 0)
    {
        Write-Host "Failed: $failCount" -ForegroundColor Red
        Write-Host "`nFailed Subscriptions:" -ForegroundColor Yellow
        foreach ($err in $errors)
        {
            Write-Host "  * $($err.SubscriptionId)" -ForegroundColor Red
            Write-Host "    $($err.Error)" -ForegroundColor Gray
        }
    }

    Write-Host ""
}

function Show-InteractiveMenu()
{
    <#
    .SYNOPSIS
        Displays interactive menu for subscription selection with input validation.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Subscriptions
    )

    Write-Host "Available Subscriptions:`n" -ForegroundColor Cyan

    # Display all subscriptions with index numbers
    for ($i = 0; $i -lt $Subscriptions.Count; $i++)
    {
        Show-SubscriptionDetails -Subscription $Subscriptions[$i] -Index $i
    }

    # Prompt for selection with validation loop
    $validSelection = $false
    $selectedIndices = @()

    while (-not $validSelection)
    {
        Write-Host "Enter subscription number(s) to delete:" -ForegroundColor Yellow
        Write-Host "  - Single: 1" -ForegroundColor Gray
        Write-Host "  - Multiple: 1,3,5" -ForegroundColor Gray
        Write-Host "  - Range: 1-4" -ForegroundColor Gray
        Write-Host "  - Press Enter to cancel" -ForegroundColor Gray
        Write-Host ""

        $selection = Read-Host "Selection"

        # User pressed Enter - exit gracefully
        if ([string]::IsNullOrWhiteSpace($selection))
        {
            Write-Host "`nOperation cancelled." -ForegroundColor Gray
            return $null
        }

        # Parse selection
        $selectedIndices = @()
        $hasInvalidInput = $false

        foreach ($part in $selection.Split(','))
        {
            $trimmed = $part.Trim()

            # Check for range (e.g., "1-4")
            if ($trimmed -match '^(\d+)-(\d+)$')
            {
                $start = [int]$Matches[1]
                $end = [int]$Matches[2]

                if ($start -le $end -and $start -ge 1 -and $end -le $Subscriptions.Count)
                {
                    $selectedIndices += ($start..$end | ForEach-Object { $_ - 1 })
                }
                else
                {
                    Write-Host "ERROR: Invalid range '$trimmed' (valid range: 1-$($Subscriptions.Count))" -ForegroundColor Red
                    $hasInvalidInput = $true
                }
            }
            # Single number
            else
            {
                $num = 0
                if ([int]::TryParse($trimmed, [ref]$num) -and $num -ge 1 -and $num -le $Subscriptions.Count)
                {
                    $selectedIndices += ($num - 1)
                }
                else
                {
                    Write-Host "ERROR: Invalid selection '$trimmed' (valid range: 1-$($Subscriptions.Count))" -ForegroundColor Red
                    $hasInvalidInput = $true
                }
            }
        }

        # Remove duplicates and sort
        $selectedIndices = $selectedIndices | Select-Object -Unique | Sort-Object

        # Validate the selection
        if ($hasInvalidInput -or $selectedIndices.Count -eq 0)
        {
            # Emit beep for invalid input
            [Console]::Beep(800, 200)
            Write-Host "`nInvalid input. Please try again.`n" -ForegroundColor Yellow
            $validSelection = $false
        }
        else
        {
            $validSelection = $true
        }
    }

    # Return selected subscriptions
    return $selectedIndices | ForEach-Object { $Subscriptions[$_] }
}

function Remove-SingleSubscription()
{
    <#
    .SYNOPSIS
        Handles deletion of a single subscription by ID.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter()]
        [bool]$SkipConfirm = $false
    )

    Write-Host "Fetching subscription details..." -ForegroundColor Cyan

    try
    {
        $subscription = Get-MgSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
        Write-Host "SUCCESS: Found subscription`n" -ForegroundColor Green

        Show-SubscriptionDetails -Subscription $subscription

        # Create array for consistent handling
        $subsToDelete = @($subscription)
        Remove-GraphSubscriptions -Subscriptions $subsToDelete -SkipConfirm $SkipConfirm
    }
    catch
    {
        if ($_.Exception.Message -like "*does not belong to application*")
        {
            Write-Host "WARNING: Cannot read subscription - it belongs to a different application." -ForegroundColor Yellow
            Write-Host "This is expected if the subscription was created by a different identity.`n" -ForegroundColor Gray

            # Try to delete anyway
            if (-not $SkipConfirm)
            {
                $response = Read-Host "Attempt to delete anyway? (y/N)"
                if ($response -ne 'y' -and $response -ne 'Y')
                {
                    Write-Host "Operation cancelled." -ForegroundColor Gray
                    return
                }
            }

            try
            {
                Write-Host "`nAttempting deletion..." -ForegroundColor Cyan
                Remove-MgSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
                Write-Host "SUCCESS: Subscription deleted." -ForegroundColor Green
            }
            catch
            {
                Write-Host "ERROR: Failed to delete subscription." -ForegroundColor Red
                Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
                throw
            }
        }
        elseif ($_.Exception.Message -like "*NotFound*" -or $_.Exception.Message -like "*does not exist*")
        {
            Write-Host "INFO: Subscription not found." -ForegroundColor Yellow
            Write-Host "It may have already been deleted or expired.`n" -ForegroundColor Gray
        }
        else
        {
            Write-Host "ERROR: Failed to retrieve subscription." -ForegroundColor Red
            Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    }
}
#endregion

#region Main Script Logic
try
{
    # Display banner
    Write-Banner -Message "Microsoft Graph Subscription Removal Tool"

    # Ensure Graph connection
    Connect-GraphIfNeeded

    # Handle different parameter sets
    switch ($PSCmdlet.ParameterSetName)
    {
        'All'
        {
            # Delete all subscriptions
            $allSubscriptions = Get-AllGraphEventgridSubscriptions
            if ($null -eq $allSubscriptions)
            {
                exit 0
            }

            Remove-GraphSubscriptions -Subscriptions $allSubscriptions -SkipConfirm $NoConfirm
        }
        'Single'
        {
            # Delete specific subscription
            Remove-SingleSubscription -SubscriptionId $graphSubscriptionId -SkipConfirm $NoConfirm
        }
        'Interactive'
        {
            # Interactive menu mode
            $allSubscriptions = Get-AllGraphEventgridSubscriptions
            if ($null -eq $allSubscriptions)
            {
                exit 0
            }
            $selectedSubscriptions = Show-InteractiveMenu -Subscriptions $allSubscriptions
            if ($null -eq $selectedSubscriptions)
            {
                exit 0
            }
            Remove-GraphSubscriptions -Subscriptions $selectedSubscriptions -SkipConfirm $NoConfirm
        }
    }

    Write-Host "Script completed successfully." -ForegroundColor Green
}
catch
{
    Write-Host "`nSCRIPT ERROR: An unexpected error occurred." -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nStack Trace:" -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
#endregion
