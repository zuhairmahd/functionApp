# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution

# NOTE: Microsoft Graph PowerShell SDK uses Connect-MgGraph with -Identity
# which is called in the function code when needed.
# Azure Functions with managed identity automatically handles authentication.

# You can also define functions or aliases that can be referenced in any of your PowerShell functions.
