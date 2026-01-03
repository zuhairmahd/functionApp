$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"
# Get all Application Insights resources from the tenant
Write-Host "Retrieving Application Insights resources..." -ForegroundColor Cyan
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

# Set the query you want to execute
$query = "customEvents | take 100"

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
                $_.rows | ForEach-Object {
                    Write-Host "Row: $($_ -join ' | ')"
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

