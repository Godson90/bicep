[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$GitHubRepository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$EnvironmentName,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$DisplayName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$DelegatableRoleDefinitionIds = @('ba92f5b4-2d11-453d-a403-e96b0029c9fe'),

    [Parameter()]
    [switch]$GrantLockManagement
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

$tenantId = az account show --subscription $SubscriptionId --query tenantId --output tsv
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the tenant ID for the subscription.'
}

if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    $DisplayName = "gh-$($GitHubRepository.Replace('/', '-'))-$EnvironmentName-deploy"
}

$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$credentialName = "github-$EnvironmentName"
$subject = "repo:${GitHubRepository}:environment:$EnvironmentName"

Write-Host "Application: $DisplayName"
Write-Host "Federated subject: $subject"
Write-Host "Role assignment scope: $scope"

# 1. Application registration (idempotent by display name).
$appId = az ad app list --display-name $DisplayName --query '[0].appId' --output tsv
if ([string]::IsNullOrWhiteSpace($appId)) {
    if ($PSCmdlet.ShouldProcess($DisplayName, 'Create Entra application registration')) {
        $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId --output tsv
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the application registration.' }
    }
    else {
        $appId = '<new-application-id>'
    }
}

# 2. Service principal.
$servicePrincipalId = $null
if ($appId -ne '<new-application-id>') {
    $servicePrincipalId = az ad sp list --filter "appId eq '$appId'" --query '[0].id' --output tsv
}
if ([string]::IsNullOrWhiteSpace($servicePrincipalId)) {
    if ($PSCmdlet.ShouldProcess($appId, 'Create service principal')) {
        $servicePrincipalId = az ad sp create --id $appId --query id --output tsv
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the service principal.' }
    }
    else {
        $servicePrincipalId = '<new-service-principal-object-id>'
    }
}

# 3. Federated credential bound to the GitHub environment.
$existingCredential = $null
if ($appId -ne '<new-application-id>') {
    $existingCredential = az ad app federated-credential list --id $appId --query "[?name=='$credentialName'].name" --output tsv
}
if ([string]::IsNullOrWhiteSpace($existingCredential)) {
    if ($PSCmdlet.ShouldProcess($subject, 'Create federated credential')) {
        $credentialFile = New-TemporaryFile
        try {
            @{
                name        = $credentialName
                issuer      = 'https://token.actions.githubusercontent.com'
                subject     = $subject
                audiences   = @('api://AzureADTokenExchange')
                description = "GitHub Actions environment '$EnvironmentName' for $GitHubRepository"
            } | ConvertTo-Json | Set-Content -Path $credentialFile -Encoding ASCII

            az ad app federated-credential create --id $appId --parameters "@$credentialFile" --output none
            if ($LASTEXITCODE -ne 0) { throw 'Failed to create the federated credential.' }
        }
        finally {
            Remove-Item $credentialFile -Force
        }
    }
}

function Set-RoleAssignment {
    param(
        [string]$Role,
        [string]$Condition
    )

    $existing = $null
    if ($servicePrincipalId -notlike '<*>') {
        $existing = az role assignment list --assignee $servicePrincipalId --role $Role --scope $scope --query '[0].id' --output tsv
    }
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "Role '$Role' already assigned at $scope."
        return
    }

    if ($PSCmdlet.ShouldProcess($scope, "Assign '$Role' to $servicePrincipalId")) {
        $arguments = @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $servicePrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $Role,
            '--scope', $scope,
            '--output', 'none'
        )
        if ($Condition) {
            $arguments += @('--condition', $Condition, '--condition-version', '2.0')
        }
        az @arguments
        if ($LASTEXITCODE -ne 0) { throw "Failed to assign '$Role'." }
    }
}

# 4. Least-privilege roles: deploy resources, and assign only the listed data-plane roles.
Set-RoleAssignment -Role 'Contributor'

$roleList = ($DelegatableRoleDefinitionIds | ForEach-Object { $_.ToLowerInvariant() }) -join ', '
$condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))"
Set-RoleAssignment -Role 'Role Based Access Control Administrator' -Condition $condition

# 5. Optional: manage CanNotDelete locks (Contributor cannot write Microsoft.Authorization/locks).
if ($GrantLockManagement) {
    $lockRoleName = 'DefenStack Resource Lock Operator'
    $lockRole = az role definition list --name $lockRoleName --custom-role-only true --query '[0].name' --output tsv
    if ([string]::IsNullOrWhiteSpace($lockRole)) {
        if ($PSCmdlet.ShouldProcess($lockRoleName, 'Create custom role')) {
            $roleFile = New-TemporaryFile
            try {
                @{
                    Name             = $lockRoleName
                    Description      = 'Create, read, and delete management locks for DefenStack deployments.'
                    Actions          = @('Microsoft.Authorization/locks/read', 'Microsoft.Authorization/locks/write', 'Microsoft.Authorization/locks/delete')
                    NotActions       = @()
                    AssignableScopes = @("/subscriptions/$SubscriptionId")
                } | ConvertTo-Json | Set-Content -Path $roleFile -Encoding ASCII

                az role definition create --role-definition "@$roleFile" --output none
                if ($LASTEXITCODE -ne 0) { throw 'Failed to create the lock operator role.' }
            }
            finally {
                Remove-Item $roleFile -Force
            }
        }
    }
    Set-RoleAssignment -Role $lockRoleName
}

$result = [pscustomobject]@{
    AZURE_CLIENT_ID       = $appId
    AZURE_TENANT_ID       = $tenantId
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
    AZURE_RESOURCE_GROUP  = $ResourceGroupName
}

Write-Host ''
Write-Host 'Set these GitHub environment variables:'
foreach ($property in $result.PSObject.Properties) {
    Write-Host "gh variable set $($property.Name) --env $EnvironmentName --repo $GitHubRepository --body '$($property.Value)'"
}

$result
