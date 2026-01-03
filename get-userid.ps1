param(
    [Parameter(Mandatory = $true)]
    [string]$UserPrincipalName,
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