param($eventGridEvent, $TriggerMetadata)

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

# Persist a human-readable record into the blob output binding
Push-OutputBinding -Name outputBlob -Value ($humanReadable -join "`n`n")

# Still log to console for quick local verification
($humanReadable -join "`n`n") | Write-Host
