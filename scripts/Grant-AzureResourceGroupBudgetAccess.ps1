[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')]
    [string]$PrincipalObjectId,

    [Parameter()]
    [ValidateSet('User', 'ServicePrincipal', 'Group', 'ForeignGroup', 'Device')]
    [string]$PrincipalType = 'User',

    [Parameter()]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = az account show --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw 'No active Azure subscription was found. Run az login or provide -SubscriptionId.'
    }
}

$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$role = 'Cost Management Contributor'

Write-Host "Assigning '$role' at: $scope"
Write-Host "Principal object ID: $PrincipalObjectId"
Write-Host "Principal type: $PrincipalType"

if ($PSCmdlet.ShouldProcess($scope, "Assign $role to $PrincipalObjectId")) {
    az role assignment create `
        --assignee-object-id $PrincipalObjectId `
        --assignee-principal-type $PrincipalType `
        --role $role `
        --scope $scope `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI failed to create the role assignment.'
    }
}
