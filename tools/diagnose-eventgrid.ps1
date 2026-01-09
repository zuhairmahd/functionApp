<#
.SYNOPSIS
    Diagnoses EventGrid event delivery issues for Microsoft Graph subscriptions.
#>

Write-Host "=== EventGrid Diagnostics ===" -ForegroundColor Cyan
Write-Host ""

# 1. Check Graph Subscription
Write-Host "1. Checking Microsoft Graph Subscription..." -ForegroundColor Yellow
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Host "   Connecting to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes "Subscription.Read.All" -NoWelcome
    }
    else {
        Write-Host "   ✅ Already connected as: $($context.Account)" -ForegroundColor Gray
    }

    $subscriptionId = "69b82601-c3c8-446f-a72c-2384784cd404"
    $graphSub = Get-MgSubscription -SubscriptionId $subscriptionId

    Write-Host "  ✅ Graph Subscription Found" -ForegroundColor Green
    Write-Host "  Resource: $($graphSub.Resource)" -ForegroundColor Gray
    Write-Host "  Notification URL: $($graphSub.NotificationUrl)" -ForegroundColor Gray
    Write-Host "  Lifecycle URL: $($graphSub.LifecycleNotificationUrl)" -ForegroundColor Gray
    Write-Host "  Change Types: $($graphSub.ChangeType)" -ForegroundColor Gray

    $expirationDateTime = [DateTime]::Parse($graphSub.ExpirationDateTime)
    $hoursUntilExpiration = ($expirationDateTime - (Get-Date)).TotalHours
    Write-Host "  Expires in: $([Math]::Round($hoursUntilExpiration, 1)) hours" -ForegroundColor Gray
    Write-Host ""
}
catch {
    Write-Host "  ❌ Error checking Graph subscription: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
}

# 2. Check EventGrid Partner Topic
Write-Host "2. Checking EventGrid Partner Topic..." -ForegroundColor Yellow
$partnerTopic = az eventgrid partner topic show `
    --name groupchangefunctiontopic `
    --resource-group groupchangefunction `
    --query "{activationState:properties.activationState, provisioningState:properties.provisioningState}" `
    -o json | ConvertFrom-Json

if ($partnerTopic.activationState -eq "Activated") {
    Write-Host "  ✅ Partner Topic is Activated" -ForegroundColor Green
}
else {
    Write-Host "  ❌ Partner Topic is NOT activated: $($partnerTopic.activationState)" -ForegroundColor Red
}
Write-Host ""

# 3. Check Event Subscription
Write-Host "3. Checking Event Subscription..." -ForegroundColor Yellow
$eventSub = az rest --method GET `
    --uri "/subscriptions/8a89e116-824d-4eeb-8ef4-16dcc1f0959b/resourceGroups/groupchangefunction/providers/Microsoft.EventGrid/partnerTopics/groupchangefunctiontopic/eventSubscriptions/FunctionApp?api-version=2022-06-15" `
    -o json | ConvertFrom-Json

Write-Host "  Provisioning State: $($eventSub.properties.provisioningState)" -ForegroundColor Gray
Write-Host "  Advanced Filter: $($eventSub.properties.filter.advancedFilters[0].key) $($eventSub.properties.filter.advancedFilters[0].operatorType)" -ForegroundColor Gray
Write-Host ""

# 4. Check EventGrid Metrics
Write-Host "4. Checking EventGrid Metrics (last 24 hours)..." -ForegroundColor Yellow
$startTime = (Get-Date).AddDays(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$metrics = az monitor metrics list `
    --resource "/subscriptions/8a89e116-824d-4eeb-8ef4-16dcc1f0959b/resourceGroups/groupchangefunction/providers/Microsoft.EventGrid/partnerTopics/groupchangefunctiontopic" `
    --metric "PublishSuccessCount,MatchedEventCount,UnmatchedEventCount,DeliverySuccessCount,DeliveryAttemptFailCount,DroppedEventCount" `
    --start-time $startTime `
    --interval PT1H `
    --aggregation Total `
    -o json | ConvertFrom-Json

foreach ($metric in $metrics.value) {
    $total = ($metric.timeseries.data | Measure-Object -Property total -Sum).Sum
    $metricName = $metric.name.value

    if ($total -gt 0) {
        Write-Host "  $metricName`: $total" -ForegroundColor Green
    }
    else {
        Write-Host "  $metricName`: $total" -ForegroundColor Gray
    }
}
Write-Host ""

# 5. Diagnosis
Write-Host "=== Diagnosis ===" -ForegroundColor Cyan
if (($metrics.value | Where-Object { $_.name.value -eq "PublishSuccessCount" }).timeseries.data.total -eq 0) {
    Write-Host "❌ NO EVENTS PUBLISHED" -ForegroundColor Red
    Write-Host "   Microsoft Graph is not sending events to EventGrid." -ForegroundColor Yellow
    Write-Host "   Possible causes:" -ForegroundColor Yellow
    Write-Host "   - No group changes have occurred" -ForegroundColor Yellow
    Write-Host "   - Graph subscription may need to be recreated" -ForegroundColor Yellow
    Write-Host "   - NotificationUrl mismatch between Graph and EventGrid" -ForegroundColor Yellow
}
elseif (($metrics.value | Where-Object { $_.name.value -eq "UnmatchedEventCount" }).timeseries.data.total -gt 0) {
    Write-Host "⚠️  EVENTS PUBLISHED BUT NOT MATCHED" -ForegroundColor Yellow
    Write-Host "   Events are arriving but the filter is rejecting them." -ForegroundColor Yellow
    Write-Host "   Check the advanced filter: $($eventSub.properties.filter.advancedFilters[0].key)" -ForegroundColor Yellow
}
elseif (($metrics.value | Where-Object { $_.name.value -eq "DeliveryAttemptFailCount" }).timeseries.data.total -gt 0) {
    Write-Host "⚠️  DELIVERY FAILURES" -ForegroundColor Yellow
    Write-Host "   Events are matched but delivery to function is failing." -ForegroundColor Yellow
}
else {
    Write-Host "✅ Configuration appears correct" -ForegroundColor Green
    Write-Host "   Waiting for group changes to trigger events..." -ForegroundColor Gray
}
