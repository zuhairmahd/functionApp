$resourceTypes = @(
    "Microsoft.ManagedIdentity/userAssignedIdentities",
    "Microsoft.Web/serverFarms",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.OperationalInsights/workspaces",
    "Microsoft.Insights/components",
    "Microsoft.Web/sites"       ,
    "microsoft.insights/actiongroups",
    "microsoft.alertsmanagement/smartDetectorAlertRules",
    "Microsoft.Web/serverFarms"
)
$rg = "groupchangefunction"

$resources = Get-AzResource -ResourceGroupName $rg | Where-Object { $resourceTypes.Contains($_.ResourceType) }
foreach ($resource in $resources)
{
    Write-Output "Deleting resource: $($resource.Name) of type $($resource.ResourceType)"
    try
    {
        if (Remove-AzResource -ResourceId $resource.ResourceId -Force)
        {
            Write-Host "Successfully deleted resource: $($resource.Name)"
        }
    }
    catch
    {
        Write-Output "Failed to delete resource: $($resource.Name). Error: $_"
    }
}