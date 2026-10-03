[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[-\w._()]{1,90}$')]
    [string[]]$ResourceGroupNames,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$GitHubRepository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$EnvironmentName,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]{1,120}$')]
    [string]$DisplayName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [ValidateScript({
            # Owner, User Access Administrator, RBAC Administrator, Contributor: never delegable.
            $privileged = @(
                '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
                '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
                'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
                'b24988ac-6180-42a0-ab88-20f7382dd24c'
            )
            if ($privileged -contains $_.ToLowerInvariant()) { throw "Role definition $_ is privileged and cannot be delegated to the pipeline." }
            $true
        })]
    [string[]]$DelegatableRoleDefinitionIds = @(
        'ba92f5b4-2d11-453d-a403-e96b0029c9fe', # Storage Blob Data Contributor (app identity, container scope)
        '1c0163c0-47e6-4577-8991-ea5c82e286e4', # Virtual Machine Administrator Login (admin group, jump host; Phase 3)
        '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1', # Storage Blob Data Reader (warm-standby app on the primary container; Phase 5)
        '3913510d-42f4-4e42-8a64-420c390055eb'  # Monitoring Metrics Publisher (App Service identity on its App Insights component; Phase 5)
    ),

    [Parameter()]
    [switch]$GrantLockManagement,

    [Parameter()]
    [ValidateRange(0, 600)]
    [int]$RoleReplicationWaitSeconds = 20
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

$subscriptionScope = "/subscriptions/$SubscriptionId"
$resourceGroupScopes = @($ResourceGroupNames | ForEach-Object { "$subscriptionScope/resourceGroups/$_" })
# The deploy workflow's plan job runs in '<env>-plan' (no reviewers) only for the environments listed here;
# every other environment's plan job runs in the gated '<env>' environment alongside apply, so it gets no
# ungated '-plan' credential. Fail closed: an environment must be explicitly opted in to get an ungated plan
# credential. Today only dev is opted in; prod (ADR-012) and any future environment (for example a 'staging')
# get no '-plan' credential unless deliberately added here.
$ungatedPlanEnvironments = @('dev')
$credentialEnvironments = if ($ungatedPlanEnvironments -contains $EnvironmentName) { @($EnvironmentName, "$EnvironmentName-plan") } else { @($EnvironmentName) }

Write-Host "Application: $DisplayName"
Write-Host "Federated subjects: $(($credentialEnvironments | ForEach-Object { "repo:${GitHubRepository}:environment:$_" }) -join ', ')"
Write-Host "Resource group scopes: $($resourceGroupScopes -join ', ')"

# 1. Application registration (idempotent by exact display name match).
$appMatches = @(az ad app list --display-name $DisplayName --query "[?displayName=='$DisplayName'].appId" --output tsv | Where-Object { $_ })
if ($LASTEXITCODE -ne 0) {
    throw "Failed to query Entra applications named '$DisplayName'."
}
if ($appMatches.Count -gt 1) {
    throw "Multiple Entra applications are named '$DisplayName'. Resolve the duplicates or pass a unique -DisplayName."
}
$appId = if ($appMatches.Count -eq 1) { $appMatches[0] } else { $null }
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

# 3. Federated credentials bound to the GitHub environments; an existing one must have exactly the same subject.
function Set-FederatedCredential {
    param(
        [string]$GitHubEnvironment
    )

    $credentialName = "github-$GitHubEnvironment"
    $subject = "repo:${GitHubRepository}:environment:$GitHubEnvironment"

    $existingSubject = $null
    if ($appId -ne '<new-application-id>') {
        $existingSubject = az ad app federated-credential list --id $appId --query "[?name=='$credentialName'].subject" --output tsv
    }
    if (-not [string]::IsNullOrWhiteSpace($existingSubject)) {
        # Entra matches subjects case-sensitively, so compare case-sensitively too.
        if ($existingSubject -cne $subject) {
            throw "Federated credential '$credentialName' exists with subject '$existingSubject', expected '$subject'. Delete it (az ad app federated-credential delete --id $appId --federated-credential-id $credentialName) and re-run."
        }
        Write-Host "Federated credential '$credentialName' already present."
        return
    }

    if ($PSCmdlet.ShouldProcess($subject, 'Create federated credential')) {
        $credentialFile = New-TemporaryFile
        try {
            @{
                name        = $credentialName
                issuer      = 'https://token.actions.githubusercontent.com'
                subject     = $subject
                audiences   = @('api://AzureADTokenExchange')
                description = "GitHub Actions environment '$GitHubEnvironment' for $GitHubRepository"
            } | ConvertTo-Json | Set-Content -Path $credentialFile -Encoding ASCII

            az ad app federated-credential create --id $appId --parameters "@$credentialFile" --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create the federated credential '$credentialName'." }
        }
        finally {
            Remove-Item $credentialFile -Force
        }
    }
}

foreach ($credentialEnvironment in $credentialEnvironments) {
    Set-FederatedCredential -GitHubEnvironment $credentialEnvironment
}

function Set-RoleAssignment {
    param(
        [string]$Role,
        [string]$Scope,
        [string]$Condition,
        [switch]$AllowReplicationRetry
    )

    $existing = $null
    if ($servicePrincipalId -notlike '<*>') {
        $existing = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].id' --output tsv
    }
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        if ($Condition) {
            $existingCondition = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].condition' --output tsv
            $normalizedExisting = ($existingCondition -replace '\s+', ' ').Trim()
            $normalizedDesired = ($Condition -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($normalizedExisting)) {
                throw "An unconditioned '$Role' assignment already exists at $Scope. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
            }
            if ($normalizedExisting -ne $normalizedDesired) {
                throw "An existing '$Role' assignment at $Scope has a different condition than expected. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
            }
        }
        Write-Host "Role '$Role' already assigned at $Scope."
        return
    }

    if ($PSCmdlet.ShouldProcess($Scope, "Assign '$Role' to $servicePrincipalId")) {
        $arguments = @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $servicePrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $Role,
            '--scope', $Scope,
            '--output', 'none'
        )
        if ($Condition) {
            $arguments += @('--condition', $Condition, '--condition-version', '2.0')
        }

        # A just-created custom role can take minutes to replicate before it can be assigned.
        $attempts = if ($AllowReplicationRetry) { 6 } else { 1 }
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            az @arguments
            if ($LASTEXITCODE -eq 0) { return }
            if ($attempt -lt $attempts) {
                Write-Host "Assignment of '$Role' failed (attempt $attempt of $attempts); waiting $RoleReplicationWaitSeconds s for role replication."
                Start-Sleep -Seconds $RoleReplicationWaitSeconds
            }
        }
        throw "Failed to assign '$Role' at $Scope."
    }
}

function Set-CustomRole {
    param(
        [string]$Name,
        [string]$Description,
        [string[]]$Actions
    )

    $existingRole = az role definition list --name $Name --custom-role-only true --query '[0].name' --output tsv
    if (-not [string]::IsNullOrWhiteSpace($existingRole)) { return }

    if ($PSCmdlet.ShouldProcess($Name, 'Create custom role')) {
        $roleFile = New-TemporaryFile
        try {
            @{
                Name             = $Name
                Description      = $Description
                Actions          = $Actions
                NotActions       = @()
                AssignableScopes = @($subscriptionScope)
            } | ConvertTo-Json | Set-Content -Path $roleFile -Encoding ASCII

            az role definition create --role-definition "@$roleFile" --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create the custom role '$Name'." }
        }
        finally {
            Remove-Item $roleFile -Force
        }
    }
}

# 4. Subscription-scope deployments only (no resource rights): the entry point targets the subscription,
#    while every resource lands in a pre-created resource group granted below.
$deploymentRoleName = 'DefenStack Subscription Deployment Operator'
Set-CustomRole -Name $deploymentRoleName -Description 'Run subscription-scope ARM deployments (validate, what-if, create) and read resource groups. Grants no resource permissions and cannot cancel or delete deployments.' -Actions @(
    'Microsoft.Resources/deployments/read',
    'Microsoft.Resources/deployments/write',
    'Microsoft.Resources/deployments/validate/action',
    'Microsoft.Resources/deployments/whatIf/action',
    'Microsoft.Resources/deployments/operations/read',
    'Microsoft.Resources/deployments/operationstatuses/read',
    'Microsoft.Resources/subscriptions/read',
    'Microsoft.Resources/subscriptions/resourceGroups/read',
    'Microsoft.Resources/subscriptions/operationresults/read'
)
Set-RoleAssignment -Role $deploymentRoleName -Scope $subscriptionScope -AllowReplicationRetry

# 5. Per resource group: deploy resources, and assign only the listed data-plane roles.
$roleList = ($DelegatableRoleDefinitionIds | ForEach-Object { $_.ToLowerInvariant() }) -join ', '
$condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))"

if ($GrantLockManagement) {
    $lockRoleName = 'DefenStack Resource Lock Operator'
    Set-CustomRole -Name $lockRoleName -Description 'Create, read, and delete management locks for DefenStack deployments.' -Actions @(
        'Microsoft.Authorization/locks/read',
        'Microsoft.Authorization/locks/write',
        'Microsoft.Authorization/locks/delete'
    )
}

foreach ($resourceGroupScope in $resourceGroupScopes) {
    Set-RoleAssignment -Role 'Contributor' -Scope $resourceGroupScope
    Set-RoleAssignment -Role 'Role Based Access Control Administrator' -Scope $resourceGroupScope -Condition $condition
    if ($GrantLockManagement) {
        Set-RoleAssignment -Role $lockRoleName -Scope $resourceGroupScope -AllowReplicationRetry
    }
}

$result = [pscustomobject]@{
    AZURE_CLIENT_ID       = $appId
    AZURE_TENANT_ID       = $tenantId
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
}

Write-Host ''
Write-Host "Create these variables on both GitHub environments '$($credentialEnvironments -join "' and '")' (Settings > Environments), or run:"
foreach ($credentialEnvironment in $credentialEnvironments) {
    foreach ($property in $result.PSObject.Properties) {
        Write-Host "gh variable set $($property.Name) --env $credentialEnvironment --repo $GitHubRepository --body '$($property.Value)'"
    }
}

$result
