Import-Module Microsoft.Graph.ChangeNotifications
$subscriptionId = "8a89e116-824d-4eeb-8ef4-16dcc1f0959b"
$resourceGroup = "groupchangefunction"
$partnerTopic = "default"
$location = "centralus"
$date = (Get-Date).AddMinutes(30)
$params = @{
    changeType               = "updated,deleted,created"
    notificationUrl          = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location"
    lifecycleNotificationUrl = "EventGrid:?azuresubscriptionid=$subscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopic&location=$location		"
    resource                 = "groups"
    expirationDateTime       = $date
    clientState              = "$(New-Guid)"
}

New-MgSubscription -BodyParameter $params