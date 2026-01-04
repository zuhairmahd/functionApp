$TimeRangeMinutes = 60
$MaxResults = 100
$includeExceptions = $true
$FunctionName = $null
$ShowSuccessOnly = $false
$ShowErrorsOnly = $false
$LogLevel = "All"

$tables = @("requests", "traces")
if ($includeExceptions)
{
    $tables += "exceptions"
}
$tablesList = $tables -join ", "

# Build filter conditions
$filters = @("timestamp > ago($($TimeRangeMinutes)m)")
if ($FunctionName)
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
| extend success = iff(itemType == 'request', success, iff(itemType == 'exception', false, true))
| extend resultCode = iff(itemType == 'request', resultCode, '')
| extend duration = iff(itemType == 'request', duration, 0.0)
| order by timestamp desc
| take $MaxResults
| project timestamp, itemType, operation_Name, message, duration, success, resultCode, severityLevel, operation_Id
"@

Write-Host "Generated Query:" -ForegroundColor Yellow
Write-Host $query -ForegroundColor White

Write-Host "`n`nJSON Body:" -ForegroundColor Yellow
$requestBody = @{
    query = $query
} | ConvertTo-Json -Depth 5
Write-Host $requestBody -ForegroundColor White
