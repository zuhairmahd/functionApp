<#
.SYNOPSIS
    Retrieves and displays logs from Azure Application Insights resources.

.DESCRIPTION
    This script connects to Azure Application Insights and queries logs from various event types
    (traces, custom events, requests, dependencies, exceptions, availability results, and page views).
    It provides both raw output and a human-readable formatted view with pagination capabilities.

    The script automatically discovers Application Insights resources in the specified subscription
    and allows the user to select which resource to query. It then retrieves logs from the selected
    time range and displays them in a formatted, color-coded view with filtering and pagination.

.PARAMETER subscriptionId
    The Azure Subscription ID to use for retrieving Application Insights resources.
    Default value: "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"

.PARAMETER timeRangeMinutes
    Time range in minutes to retrieve logs from Application Insights.
    Specifies how far back in time to query for log events.
    Default value: 30 minutes

.PARAMETER numberOfEvents
    Number of log events to retrieve from Application Insights.
    This limits the total number of events returned by the query.
    Default value: 1000 events

.PARAMETER messageLength
    Maximum length of log message to display in human-readable mode.
    Messages longer than this will be truncated with "..." appended.
    Default value: 500 characters

.PARAMETER entriesPerPage
    Number of log entries to display per page in human-readable mode.
    Controls the pagination size when viewing logs.
    Default value: 15 entries

.PARAMETER raw
    If set, outputs raw log data without filtering or formatting.
    When not set, logs are formatted, cleaned, and paginated for better readability.

.EXAMPLE
    .\GetLogs.ps1
    Retrieves logs from the last 30 minutes using default settings with interactive resource selection.

.EXAMPLE
    .\GetLogs.ps1 -timeRangeMinutes 60 -numberOfEvents 500
    Retrieves the last 500 log events from the past 60 minutes.

.EXAMPLE
    .\GetLogs.ps1 -subscriptionId "your-subscription-id" -raw
    Retrieves logs in raw format without cleaning or pagination from the specified subscription.

.EXAMPLE
    .\GetLogs.ps1 -timeRangeMinutes 120 -entriesPerPage 25 -messageLength 1000
    Retrieves logs from the last 2 hours, displaying 25 entries per page with longer message lengths.

.NOTES
    Author: [Your Name]
    Prerequisites:
    - Azure PowerShell modules must be installed (Az.ApplicationInsights, Az.Accounts)
    - User must be authenticated to Azure (Connect-AzAccount)
    - User must have read permissions on Application Insights resources

    The script uses the Application Insights REST API to query logs and requires proper
    Azure authentication. It automatically handles SecureString tokens for security.

.LINK
    https://docs.microsoft.com/azure/azure-monitor/app/app-insights-overview

.LINK
    https://docs.microsoft.com/rest/api/application-insights/

#>
[CmdletBinding()                            ]
param(
    [Parameter(
        HelpMessage = "Azure Subscription ID to use for retrieving Application Insights resources.",
        ValueFromPipelineByPropertyName = $true,
        Position = 0
    )]
    [string]$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b",
    [Parameter(
        HelpMessage = "Time range in minutes to retrieve logs from Application Insights."
    )                               ]
    [int]$timeRangeMinutes = 30,
    [Parameter(
        HelpMessage = "Number of log events to retrieve."
    )]
    [int]$numberOfEvents = 1000,
    [Parameter(
        HelpMessage = "Maximum length of log message to display."
    )]
    [int]$messageLength = 500,
    [Parameter(
        HelpMessage = "Number of log entries to display per page in human-readable mode."
    )]
    [int]$entriesPerPage = 15,
    [Parameter(
        HelpMessage = "If set, outputs raw log data without filtering or formatting."
    )]
    [switch]$raw
)

# Check if user is logged in to Azure
Write-Host "Checking Azure authentication status..." -ForegroundColor Cyan
try
{
    $context = Get-AzContext -ErrorAction Stop
    if ($null -eq $context -or $null -eq $context.Account)
    {
        Write-Host "Not logged in to Azure. Connecting..." -ForegroundColor Yellow
        Connect-AzAccount
        # Verify login was successful
        $context = Get-AzContext -ErrorAction Stop
        if ($null -eq $context -or $null -eq $context.Account)
        {
            Write-Host "❌ Failed to authenticate to Azure. Exiting." -ForegroundColor Red
            exit
        }
    }
    Write-Host "✅ Already authenticated as: $($context.Account.Id)" -ForegroundColor Green
}
catch
{
    Write-Host "Error checking Azure authentication: $_" -ForegroundColor Red
    Write-Host "Attempting to login..." -ForegroundColor Yellow
    Connect-AzAccount

    # Verify login was successful
    try
    {
        $context = Get-AzContext -ErrorAction Stop
        if ($null -eq $context -or $null -eq $context.Account)
        {
            Write-Host "❌ Failed to authenticate to Azure. Exiting." -ForegroundColor Red
            exit
        }
        Write-Host "✅ Authenticated as: $($context.Account.Id)" -ForegroundColor Green
    }
    catch
    {
        Write-Host "Failed to authenticate to Azure. Exiting." -ForegroundColor Red
        exit
    }
}

# Get all Application Insights resources from the tenant
Write-Host "`nRetrieving Application Insights resources..." -ForegroundColor Cyan
$appInsightsResources = Get-AzApplicationInsights -SubscriptionId $subscriptionId
# Check if any resources were found
if ($appInsightsResources.Count -eq 0)
{
    Write-Host "No Application Insights resources found in the current subscription." -ForegroundColor Red
    exit
}
elseif ($appInsightsResources.Count -eq 1)
{
    $selectedResource = $appInsightsResources[0]
    $appId = $selectedResource.AppId
}
else
{
    Write-Host "Found $($appInsightsResources.Count) Application Insights resources." -ForegroundColor Green
    # Display the list of Application Insights resources
    for ($i = 0; $i -lt $appInsightsResources.Count; $i++)
    {
        Write-Host "[$($i+1)]. Name: $($appInsightsResources[$i].Name) | Resource Group: $($appInsightsResources[$i].ResourceGroupName) | Location: $($appInsightsResources[$i].Location)"
    }
    Write-Host "[0]. Exit" -ForegroundColor Yellow
    # Prompt user to select an Application Insights resource
    Write-Host "`nEnter the number of the Application Insights resource you want to query (or 0 to exit):" -ForegroundColor Yellow
    $selection = Read-Host
    # Validate the selection
    while ($selection -notmatch '^\d+$' -or [int]$selection -lt 0 -or [int]$selection -gt $appInsightsResources.Count)
    {
        Write-Host "Invalid selection. Please select a valid number." -ForegroundColor Red
        [console]::beep(1000, 300)
        $selection = Read-Host
    }

    # Check if user wants to exit
    if ([int]$selection -eq 0)
    {
        Write-Host "Exiting script." -ForegroundColor Yellow
        exit
    }
    # Get the selected Application Insights resource
    $selectedResource = $appInsightsResources[[int]$selection - 1]
    $appId = $selectedResource.AppId
}
Write-Host "`nSelected Application Insights: $($selectedResource.Name)" -ForegroundColor Green
Write-Host "App ID: $appId" -ForegroundColor Cyan

# Set the access token for the Application Insights resource
$tokenObject = Get-AzAccessToken -ResourceUrl "https://api.applicationinsights.io"
# Extract the token as a plain string
if ($tokenObject -and $tokenObject.Token)
{
    # If Token is a SecureString, convert it
    if ($tokenObject.Token -is [System.Security.SecureString])
    {
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObject.Token)
        $accessToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
    else
    {
        $accessToken = $tokenObject.Token
    }
}
else
{
    Write-Host "Failed to retrieve access token. Please ensure you are logged in to Azure." -ForegroundColor Red
    exit
}

# Verify the access token was retrieved successfully
if ([string]::IsNullOrEmpty($accessToken))
{
    Write-Host "Failed to retrieve access token. Please ensure you are logged in to Azure." -ForegroundColor Red
    exit
}

# Set the query you want to execute - retrieves all event types with type identification
if ($raw)
{
    # Raw mode: Get all columns
    $query = "union
    (traces | extend eventType = 'trace'),
    (customEvents | extend eventType = 'customEvent'),
    (requests | extend eventType = 'request'),
    (dependencies | extend eventType = 'dependency'),
    (exceptions | extend eventType = 'exception'),
    (availabilityResults | extend eventType = 'availabilityResult'),
    (pageViews | extend eventType = 'pageView')
| where timestamp > ago($($timeRangeMinutes)m)
| take $numberOfEvents
| order by timestamp desc"
}
else
{
    # Normal mode: Project specific columns
    $query = "union
    (traces | extend eventType = 'trace'),
    (customEvents | extend eventType = 'customEvent'),
    (requests | extend eventType = 'request'),
    (dependencies | extend eventType = 'dependency'),
    (exceptions | extend eventType = 'exception'),
    (availabilityResults | extend eventType = 'availabilityResult'),
    (pageViews | extend eventType = 'pageView')
| where timestamp > ago($($timeRangeMinutes)m)
| project timestamp, user_Id, user_AuthenticatedId, success, details, operation_Name, eventType, severityLevel, name, message
| take $numberOfEvents
| order by timestamp desc"
}

# Construct the request body for the Application Insights query endpoint
$requestBody = @{
    query = $query
} | ConvertTo-Json

# Execute the query and retrieve the results
Write-Host "Executing query against Application Insights..." -ForegroundColor Cyan
try
{
    $queryResponse = Invoke-RestMethod -Method POST -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" -Headers @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type"  = "application/json"
    } -Body $requestBody

    # Print the results
    Write-Host "`nQuery Results:" -ForegroundColor Green
    if ($queryResponse.tables -and $queryResponse.tables.Count -gt 0)
    {
        Write-Host "Number of tables returned: $($queryResponse.tables.Count)" -ForegroundColor Green
        $queryResponse.tables | ForEach-Object {
            Write-Host "Table: $($_.name)" -ForegroundColor Yellow
            Write-Host "Column count: $($_.columns.Count)" -ForegroundColor Cyan
            Write-Host "Row Count: $($_.rows.Count)" -ForegroundColor Cyan
            Write-Host "Columns: $($_.columns.name -join ', ')" -ForegroundColor Cyan

            # Display the rows in a formatted way
            if ($_.rows.Count -gt 0)
            {
                if ($raw)
                {
                    # Raw output - display all data as-is
                    $_.rows | ForEach-Object {
                        Write-Host "Row: $($_ -join ' | ')"
                    }
                }
                else
                {
                    # Human-readable output - filter and format the data with paging
                    $totalRows = $_.rows.Count
                    $totalPages = [Math]::Ceiling($totalRows / $entriesPerPage)
                    $currentPage = 1
                    $exitPaging = $false

                    # Function to display a page of logs
                    function Show-LogPage
                    {
                        param(
                            [array]$rows,
                            [int]$page,
                            [int]$totalPages,
                            [int]$pageSize
                        )

                        Clear-Host
                        Write-Host "`n--- Filtered Log Entries (Page $page of $totalPages) ---`n" -ForegroundColor Magenta

                        $startIndex = ($page - 1) * $pageSize
                        $endIndex = [Math]::Min($startIndex + $pageSize - 1, $rows.Count - 1)

                        for ($i = $startIndex; $i -le $endIndex; $i++)
                        {
                            $row = $rows[$i]
                            $rowIndex = $i + 1
                            # Column indices based on projection: timestamp, user_Id, user_AuthenticatedId, success, details, operation_Name, eventType, severityLevel, name, message
                            $timestamp = $row[0]
                            $user_Id = $row[1]
                            $user_AuthenticatedId = $row[2]
                            $success = $row[3]
                            $details = $row[4]
                            $operation_Name = $row[5]
                            $eventType = $row[6]
                            $severityLevel = $row[7]
                            $name = $row[8]
                            $message = $row[9]

                            # Format timestamp
                            $formattedTime = if ($timestamp)
                            {
                                try
                                {
                                    $dt = [DateTime]::Parse($timestamp)
                                    $dt.ToString("yyyy-MM-dd HH:mm:ss")
                                }
                                catch
                                {
                                    $timestamp
                                }
                            }
                            else
                            {
                                "N/A"
                            }

                            # Clean up message by removing GUIDs, request IDs, and excessive detail
                            $cleanMessage = $message
                            if ($cleanMessage -and -not [string]::IsNullOrWhiteSpace($cleanMessage))
                            {
                                # Remove GUIDs (pattern: 8-4-4-4-12 hex digits)
                                $cleanMessage = $cleanMessage -replace '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '[GUID]'

                                # Remove long URLs, keeping just the essential part
                                $cleanMessage = $cleanMessage -replace 'https?://[^\s\r\n]+', '[URL]'

                                # Remove request/response headers and detailed technical info
                                $cleanMessage = $cleanMessage -replace '(?s)Request \[.*?\].*?Authorization:REDACTED.*?(?=client assembly:|$)', '[HTTP Request Details]'
                                $cleanMessage = $cleanMessage -replace '(?s)Response \[.*?\].*?(?=\r\n\r\n|$)', '[HTTP Response Details]'

                                # Remove x-ms headers and similar technical details
                                $cleanMessage = $cleanMessage -replace '\\r\\n[x-][^\r\n]+', ''
                                $cleanMessage = $cleanMessage -replace 'x-ms-[^:\s]+:[^\r\n]+', ''

                                # Clean up multiple spaces and newlines
                                $cleanMessage = $cleanMessage -replace '\s+', ' '
                                $cleanMessage = $cleanMessage.Trim()

                                # Limit message length for readability
                                if ($cleanMessage.Length -gt $messageLength)
                                {
                                    $cleanMessage = $cleanMessage.Substring(0, $messageLength) + "..."
                                }
                            }

                            # Display formatted entry
                            Write-Host "[$rowIndex] " -NoNewline -ForegroundColor DarkGray
                            Write-Host "$formattedTime " -NoNewline -ForegroundColor Gray

                            # Color code by event type
                            $eventColor = switch ($eventType)
                            {
                                'trace'
                                {
                                    'Cyan'
                                }
                                'request'
                                {
                                    'Green'
                                }
                                'dependency'
                                {
                                    'Blue'
                                }
                                'exception'
                                {
                                    'Red'
                                }
                                'customEvent'
                                {
                                    'Magenta'
                                }
                                default
                                {
                                    'White'
                                }
                            }
                            Write-Host "[$eventType] " -NoNewline -ForegroundColor $eventColor

                            # Display severity level if present and meaningful
                            if ($severityLevel -and $severityLevel -ne "0" -and -not [string]::IsNullOrWhiteSpace($severityLevel))
                            {
                                $severityColor = switch ($severityLevel)
                                {
                                    "0"
                                    {
                                        'Gray'
                                    }      # Verbose
                                    "1"
                                    {
                                        'Cyan'
                                    }      # Information
                                    "2"
                                    {
                                        'Yellow'
                                    }    # Warning
                                    "3"
                                    {
                                        'Red'
                                    }       # Error
                                    "4"
                                    {
                                        'DarkRed'
                                    }   # Critical
                                    default
                                    {
                                        'White'
                                    }
                                }
                                Write-Host "[Sev:$severityLevel] " -NoNewline -ForegroundColor $severityColor
                            }

                            if ($name -and -not [string]::IsNullOrWhiteSpace($name))
                            {
                                Write-Host "$name" -NoNewline -ForegroundColor Yellow
                            }

                            # Display additional fields if they contain useful values
                            $additionalInfo = @()
                            if ($user_Id -and -not [string]::IsNullOrWhiteSpace($user_Id))
                            {
                                $additionalInfo += "User:$user_Id"
                            }
                            if ($user_AuthenticatedId -and -not [string]::IsNullOrWhiteSpace($user_AuthenticatedId))
                            {
                                $additionalInfo += "AuthUser:$user_AuthenticatedId"
                            }
                            if ($operation_Name -and -not [string]::IsNullOrWhiteSpace($operation_Name))
                            {
                                $additionalInfo += "Op:$operation_Name"
                            }
                            if ($success -ne $null -and $success -ne "")
                            {
                                $successText = if ($success -eq "True" -or $success -eq $true)
                                {
                                    "+"
                                }
                                else
                                {
                                    "-"
                                }
                                $successColor = if ($success -eq "True" -or $success -eq $true)
                                {
                                    "Green"
                                }
                                else
                                {
                                    "Red"
                                }
                                $additionalInfo += $successText
                            }
                            if ($details -and -not [string]::IsNullOrWhiteSpace($details))
                            {
                                $shortDetails = if ($details.Length -gt 50)
                                {
                                    $details.Substring(0, 47) + "..."
                                }
                                else
                                {
                                    $details
                                }
                                $additionalInfo += "Details:$shortDetails"
                            }

                            if ($additionalInfo.Count -gt 0)
                            {
                                Write-Host " [" -NoNewline -ForegroundColor DarkGray
                                Write-Host ($additionalInfo -join " | ") -NoNewline -ForegroundColor DarkCyan
                                Write-Host "]" -NoNewline -ForegroundColor DarkGray
                            }

                            if ($cleanMessage -and -not [string]::IsNullOrWhiteSpace($cleanMessage))
                            {
                                Write-Host " - $cleanMessage" -ForegroundColor White
                            }
                            else
                            {
                                Write-Host ""
                            }
                        }

                        Write-Host "`n--- End of Page $page ---`n" -ForegroundColor Magenta
                    }

                    # Paging loop
                    while (-not $exitPaging)
                    {
                        Show-LogPage -rows $_.rows -page $currentPage -totalPages $totalPages -pageSize $entriesPerPage

                        # Show navigation options
                        Write-Host "Navigation Options:" -ForegroundColor Yellow
                        Write-Host "  [N] Next Page" -ForegroundColor Green
                        Write-Host "  [P] Previous Page" -ForegroundColor Green
                        Write-Host "  [G] Go to Page" -ForegroundColor Green
                        Write-Host "  [Q] Quit Paging" -ForegroundColor Red
                        Write-Host "`nCurrent Page: $currentPage of $totalPages | Total Entries: $totalRows" -ForegroundColor Cyan
                        Write-Host "Enter your choice: " -NoNewline -ForegroundColor Yellow

                        $choice = Read-Host

                        switch ($choice.ToUpper())
                        {
                            'N'
                            {
                                if ($currentPage -lt $totalPages)
                                {
                                    $currentPage++
                                }
                                else
                                {
                                    Write-Host "Already on the last page." -ForegroundColor Yellow
                                    Start-Sleep -Seconds 1
                                }
                            }
                            'P'
                            {
                                if ($currentPage -gt 1)
                                {
                                    $currentPage--
                                }
                                else
                                {
                                    Write-Host "Already on the first page." -ForegroundColor Yellow
                                    Start-Sleep -Seconds 1
                                }
                            }
                            'G'
                            {
                                Write-Host "Enter page number (1-$totalPages): " -NoNewline -ForegroundColor Yellow
                                $pageInput = Read-Host
                                if ($pageInput -match '^\d+$')
                                {
                                    $requestedPage = [int]$pageInput
                                    if ($requestedPage -ge 1 -and $requestedPage -le $totalPages)
                                    {
                                        $currentPage = $requestedPage
                                    }
                                    else
                                    {
                                        Write-Host "Invalid page number. Please enter a number between 1 and $totalPages." -ForegroundColor Red
                                        Start-Sleep -Seconds 2
                                    }
                                }
                                else
                                {
                                    Write-Host "Invalid input. Please enter a numeric page number." -ForegroundColor Red
                                    Start-Sleep -Seconds 2
                                }
                            }
                            'Q'
                            {
                                Write-Host "`nExiting paging view..." -ForegroundColor Green
                                $exitPaging = $true
                            }
                            default
                            {
                                Write-Host "Invalid choice. Please select N, P, G, or Q." -ForegroundColor Red
                                Start-Sleep -Seconds 1
                            }
                        }
                    }
                }
            }
        }
    }
    else
    {
        Write-Host "No results returned from the query." -ForegroundColor Yellow
    }
    $global:r = $queryResponse
}
catch
{
    Write-Host "Error executing query: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Error Details: $($_.ErrorDetails.Message)" -ForegroundColor Red
}

