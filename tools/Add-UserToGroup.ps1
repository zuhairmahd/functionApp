param(
    [Parameter()]
    [string]$UserPrincipalName = "zuhair@arabictutor.com",
    [string]$group,
    [switch]$remove
)

$groupId = if ($group)
{
    $group
}
else
{
    "817f24e3-ba30-41fb-a932-cc912fa08c73"
}

#check if we are connected to graph
if (-not (Get-MgContext))
{
    Write-Host "Not connected to Microsoft Graph.  Will try to connect..." -ForegroundColor Yellow
    try
    {
        Connect-MgGraph -Scopes "Group.ReadWrite.All", "User.Read.All", "Device.ReadWrite.All                   " -NoWelcome -ErrorAction Stop
        Write-Host "Connected to Microsoft Graph successfully." -ForegroundColor Green
    }
    catch
    {
        Write-Host "Failed to connect to Microsoft Graph. Please ensure you have the necessary permissions." -ForegroundColor Red
        exit 1
    }
}

$success = $false
# Look up user by UPN and store in variable
$user = Get-MgUser -UserId $UserPrincipalName
$directoryObjectId = $user.Id
if ($remove)
{
    # Check if user is already a member of the group
    $isMember = Get-MgGroupMember -GroupId $groupId -All | Where-Object { $_.Id -eq $directoryObjectId }
    if ($isMember)
    {
        Write-Host "Removing user $UserPrincipalName from group $groupId"
        $success = Remove-MgGroupMemberDirectoryObjectByRef -GroupId $groupId -DirectoryObjectId $directoryObjectId -PassThru
        if ($success)
        {
            Write-Host "User $UserPrincipalName removed from group $groupId successfully."
        }
        else
        {
            Write-Host "Failed to remove user $UserPrincipalName from group $groupId."
        }
    }
    else
    {
        Write-Host "User $UserPrincipalName is not a member of group $groupId"
    }
}
else
{
    # Check if user is already a member of the group
    $isMember = Get-MgGroupMember -GroupId $groupId -All | Where-Object { $_.Id -eq $directoryObjectId }
    if (-not $isMember)
    {
        Write-Host "Adding user $UserPrincipalName to group $groupId"
        $success = New-MgGroupMemberByRef -GroupId $groupId -BodyParameter @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$directoryObjectId"
        } -PassThru
        if ($success)
        {
            Write-Host "User $UserPrincipalName added to group $groupId successfully."
        }
        else
        {
            Write-Host "Failed to add user $UserPrincipalName to group $groupId."
        }
    }
    else
    {
        Write-Host "User $UserPrincipalName is already a member of group $groupId"
    }
}