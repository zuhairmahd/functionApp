<#
.SYNOPSIS
    Retrieves Azure Function App execution logs from Application Insights.

.DESCRIPTION
    This script queries Application Insights to retrieve function execution logs, traces, and errors.
    It provides filtered views of function invocations, exceptions, and detailed execution information.

.PARAMETER FunctionName
    The name of the specific function to query logs for. If not specified, shows logs for all functions.

.PARAMETER TimeRangeMinutes
    Time range in minutes to retrieve logs. Default: 60 minutes.

.PARAMETER MaxResults
    Maximum number of log entries to return. Default: 100.

.PARAMETER LogLevel
    Filter by log level: All, Trace, Information, Warning, Error. Default: All.

.PARAMETER ShowSuccessOnly
    If set, shows only successful executions.

.PARAMETER ShowErrorsOnly
    If set, shows only failed executions.

.PARAMETER Raw
    If set, outputs raw log data without formatting.

.EXAMPLE
    .\Get-FunctionLogs.ps1
    Retrieves all function logs from the last hour

.EXAMPLE
    .\Get-FunctionLogs.ps1 -FunctionName "EventGridTrigger1" -TimeRangeMinutes 120
    Retrieves logs for EventGridTrigger1 from the last 2 hours

.EXAMPLE
    .\Get-FunctionLogs.ps1 -ShowErrorsOnly -TimeRangeMinutes 1440
    Shows only errors from the last 24 hours

.EXAMPLE
    .\Get-FunctionLogs.ps1 -FunctionName "RenewSubscription" -LogLevel Warning
    Shows warnings and errors for the RenewSubscription function
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$FunctionName,
    [Parameter()]
    [int]$TimeRangeMinutes = 60,
    [Parameter()]
    [int]$MaxResults = 1000,
    [Parameter()]
    [ValidateSet("All", "Trace", "Information", "Warning", "Error")]
    [string]$LogLevel = "All",
    [Parameter()]
    [switch]$ShowSuccessOnly,
    [Parameter()]
    [switch]$ShowErrorsOnly,
    [Parameter()]
    [switch]$displayQuery,
    [Parameter()]
    [switch]$Raw
)

$ErrorActionPreference = "Stop"

# Configuration
$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"
$resourceGroup = "groupchangefunction"

Write-Host "Azure Function App Log Retrieval" -ForegroundColor Cyan

# Check Azure authentication
Write-Host "Checking Azure authentication..." -ForegroundColor Cyan
try
{
    $context = Get-AzContext -ErrorAction Stop
    if ($null -eq $context -or $null -eq $context.Account)
    {
        Write-Host "Not logged in to Azure. Connecting..." -ForegroundColor Yellow
        Connect-AzAccount
        $context = Get-AzContext -ErrorAction Stop
        Write-Host "✅ Authenticated as: $($context.Account.Id)`n" -ForegroundColor Green
    }
    else
    {
        Write-Host "✅ Already authenticated as: $($context.Account.Id)`n" -ForegroundColor Green
    }
}
catch
{
    Write-Host "❌ Failed to authenticate to Azure" -ForegroundColor Red
    exit 1
}

# Get Application Insights resources
Write-Host "Finding Application Insights resource..." -ForegroundColor Cyan
$appInsightsResources = Get-AzApplicationInsights -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup

if ($appInsightsResources.Count -eq 0)
{
    Write-Host "❌ No Application Insights resources found in resource group: $resourceGroup" -ForegroundColor Red
    exit 1
}

$appInsights = $appInsightsResources[0]
$appId = $appInsights.AppId

Write-Host "✅ Found Application Insights: $($appInsights.Name)" -ForegroundColor Green
Write-Host "   App ID: $appId`n" -ForegroundColor Gray

# Get access token
$tokenObject = Get-AzAccessToken -ResourceUrl "https://api.applicationinsights.io"
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

# Build the KQL query
Write-Host "Building query..." -ForegroundColor Cyan

# Build function filter
$functionFilter = if ($FunctionName)
{
    "operation_Name contains '$FunctionName'"
}
else
{
    $null
}

# Skip exceptions if ShowSuccessOnly is set
$includeExceptions = -not $ShowSuccessOnly

# Main query combining requests, traces, and exceptions
# Build a simple union query based on Microsoft docs examples
$tables = @("requests", "traces")
if ($includeExceptions)
{
    $tables += "exceptions"
}
$tablesList = $tables -join ", "

# Build filter conditions
$filters = @("timestamp > ago($($TimeRangeMinutes)m)")
if ($functionFilter)
{
    $filters += "operation_Name contains '$FunctionName'"
}

# Add filters based on parameters
if ($ShowSuccessOnly)
{
    $filters += "(itemType == 'request' and success == true) or itemType != 'request'"
}
if ($ShowErrorsOnly)
{
    $filters += "(itemType == 'request' and success == false) or itemType == 'exception' or (itemType == 'trace' and severityLevel >= 3)"
}

# Log level filters for traces
if ($LogLevel -eq "Warning")
{
    $filters += "itemType != 'trace' or severityLevel == 2"
}
elseif ($LogLevel -eq "Error")
{
    $filters += "itemType != 'trace' or severityLevel >= 3"
}
elseif ($LogLevel -eq "Information")
{
    $filters += "itemType != 'trace' or severityLevel <= 1"
}
elseif ($LogLevel -eq "Trace")
{
    $filters += "itemType != 'trace' or severityLevel == 0"
}

$whereClause = $filters -join " and "

$query = @"
union $tablesList
| where $whereClause
| extend message = iff(itemType == 'exception', outerMessage, iff(itemType == 'request', name, message))
| extend success = iff(itemType == 'request', tobool(success), iff(itemType == 'exception', tobool(false), tobool(true)))
| extend resultCode = iff(itemType == 'request', tostring(resultCode), '')
| extend duration = iff(itemType == 'request', todouble(duration), 0.0)
| order by timestamp desc
| take $MaxResults
| project timestamp, itemType, operation_Name, message, duration, success, resultCode, severityLevel, operation_Id
"@
if ($displayQuery)
{
    Write-Host "Query parameters:" -ForegroundColor Gray
    Write-Host "  Time range: Last $TimeRangeMinutes minutes" -ForegroundColor Gray
    Write-Host "  Max results: $MaxResults" -ForegroundColor Gray
    if ($FunctionName)
    {
        Write-Host "  Function: $FunctionName" -ForegroundColor Gray
    }
    if ($ShowSuccessOnly)
    {
        Write-Host "  Filter: Success only" -ForegroundColor Gray
    }
    if ($ShowErrorsOnly)
    {
        Write-Host "  Filter: Errors only" -ForegroundColor Gray
    }
    if ($LogLevel -ne "All")
    {
        Write-Host "  Log level: $LogLevel" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Generated Query:" -ForegroundColor Yellow
    Write-Host $query -ForegroundColor Gray
    Write-Host ""
}
# Execute the query
Write-Host "Querying Application Insights..." -ForegroundColor Cyan

$requestBody = @{
    query = $query
} | ConvertTo-Json

try
{
    $response = Invoke-RestMethod -Method POST `
        -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" `
        -Headers @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type"  = "application/json"
    } `
        -Body $requestBody

    if ($response.tables.Count -eq 0 -or $response.tables[0].rows.Count -eq 0)
    {
        Write-Host "No logs found matching the criteria." -ForegroundColor Yellow
        Write-Host "`nTips:" -ForegroundColor Yellow
        Write-Host "  - Try increasing the time range: -TimeRangeMinutes 1440 (24 hours)" -ForegroundColor Gray
        Write-Host "  - Check if the function has been triggered recently" -ForegroundColor Gray
        Write-Host "  - Verify Application Insights is properly configured" -ForegroundColor Gray
        exit 0
    }

    $table = $response.tables[0]
    $columns = $table.columns
    $rows = $table.rows

    Write-Host "✅ Found $($rows.Count) log entries`n" -ForegroundColor Green

    if ($Raw)
    {
        # Raw output
        $rows | ForEach-Object {
            $row = $_
            $obj = [ordered]@{}
            for ($i = 0; $i -lt $columns.Count; $i++)
            {
                $obj[$columns[$i].name] = $row[$i]
            }
            [PSCustomObject]$obj
        }
    }
    else
    {
        # Formatted output
        Write-Host "================================================" -ForegroundColor Cyan
        Write-Host "Function Execution Logs" -ForegroundColor Cyan
        Write-Host "================================================`n" -ForegroundColor Cyan

        $counter = 1
        foreach ($row in $rows)
        {
            # Parse row data
            $timestamp = [DateTime]::Parse($row[0])
            $itemType = $row[1]
            $operationName = $row[2]
            $message = $row[3]
            $duration = [Math]::Round($row[4], 2)
            $success = $row[5]
            $resultCode = $row[6]
            $severityLevel = $row[7]
            $operationId = $row[8]

            # Color coding
            $eventColor = switch ($itemType)
            {
                'request'
                {
                    'Cyan'
                }
                'trace'
                {
                    'Gray'
                }
                'exception'
                {
                    'Red'
                }
                default
                {
                    'White'
                }
            }

            $successIcon = if ($success -eq $true)
            {
                "✅"
            }
            elseif ($success -eq $false)
            {
                "❌"
            }
            else
            {
                "➖"
            }

            # Display entry
            Write-Host "[$counter] " -NoNewline -ForegroundColor DarkGray
            Write-Host $timestamp.ToString("yyyy-MM-dd HH:mm:ss") -NoNewline -ForegroundColor Gray
            Write-Host " | " -NoNewline -ForegroundColor DarkGray
            Write-Host $itemType.ToUpper().PadRight(10) -NoNewline -ForegroundColor $eventColor
            Write-Host " | " -NoNewline -ForegroundColor DarkGray
            Write-Host $successIcon -ForegroundColor $(if ($success)
                {
                    "Green"
                }
                else
                {
                    "Red"
                })

            if ($operationName)
            {
                Write-Host "   Function: " -NoNewline -ForegroundColor DarkGray
                Write-Host $operationName -ForegroundColor Yellow
            }

            if ($duration -gt 0)
            {
                Write-Host "   Duration: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($duration)ms" -ForegroundColor $(if ($duration -gt 5000)
                    {
                        "Yellow"
                    }
                    else
                    {
                        "Gray"
                    })
            }

            if ($resultCode)
            {
                Write-Host "   Result Code: " -NoNewline -ForegroundColor DarkGray
                Write-Host $resultCode -ForegroundColor $(if ($resultCode -like "2*")
                    {
                        "Green"
                    }
                    else
                    {
                        "Red"
                    })
            }

            if ($message)
            {
                # Clean up message
                $cleanMessage = $message -replace '\r\n', ' ' -replace '\n', ' '
                if ($cleanMessage.Length -gt 200)
                {
                    $cleanMessage = $cleanMessage.Substring(0, 197) + "..."
                }
                Write-Host "   Message: " -NoNewline -ForegroundColor DarkGray
                Write-Host $cleanMessage -ForegroundColor White
            }

            if ($operationId)
            {
                Write-Host "   Operation ID: " -NoNewline -ForegroundColor DarkGray
                Write-Host $operationId -ForegroundColor DarkGray
            }

            Write-Host ""
            $counter++
        }

        # Summary statistics
        $totalRequests = ($rows | Where-Object { $_[1] -eq 'request' }).Count
        $successfulRequests = ($rows | Where-Object { $_[1] -eq 'request' -and $_[5] -eq $true }).Count
        $failedRequests = ($rows | Where-Object { $_[1] -eq 'request' -and $_[5] -eq $false }).Count
        $exceptions = ($rows | Where-Object { $_[1] -eq 'exception' }).Count

        if ($totalRequests -gt 0)
        {
            Write-Host "================================================" -ForegroundColor Cyan
            Write-Host "Summary" -ForegroundColor Cyan
            Write-Host "================================================" -ForegroundColor Cyan
            Write-Host "Total Requests: $totalRequests" -ForegroundColor White
            Write-Host "Successful: $successfulRequests " -NoNewline -ForegroundColor Green
            if ($totalRequests -gt 0)
            {
                Write-Host "($([Math]::Round($successfulRequests/$totalRequests*100, 1))%)" -ForegroundColor Green
            }
            if ($failedRequests -gt 0)
            {
                Write-Host "Failed: $failedRequests " -NoNewline -ForegroundColor Red
                Write-Host "($([Math]::Round($failedRequests/$totalRequests*100, 1))%)" -ForegroundColor Red
            }
            if ($exceptions -gt 0)
            {
                Write-Host "Exceptions: $exceptions" -ForegroundColor Red
            }
        }
    }
}
catch
{
    Write-Host "❌ Error querying logs: $($_.Exception.Message)" -ForegroundColor Red

    # Try to get more detail from the error
    if ($_.Exception.Response)
    {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEnd()
        Write-Host "API Error Response:" -ForegroundColor Yellow
        Write-Host $responseBody -ForegroundColor Red
    }

    Write-Host "`nQuery that was sent:" -ForegroundColor Yellow
    Write-Host $query -ForegroundColor Gray
    exit 1
}
