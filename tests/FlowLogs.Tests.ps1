BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $storageTemplate = Get-BicepTemplate -RelativePath 'modules/flowLogStorage.bicep'
    $account = Get-TemplateResource -Template $storageTemplate -Type 'Microsoft.Storage/storageAccounts' | Select-Object -First 1
    $identity = Get-TemplateResource -Template $storageTemplate -Type 'Microsoft.ManagedIdentity/userAssignedIdentities' | Select-Object -First 1
    $assignments = @(Get-TemplateResource -Template $storageTemplate -Type 'Microsoft.Authorization/roleAssignments')
    $flowLogTemplate = Get-BicepTemplate -RelativePath 'modules/flowLogs.bicep'
    $flowLog = Get-TemplateResource -Template $flowLogTemplate -Type 'Microsoft.Network/networkWatchers/flowLogs' | Select-Object -First 1
    $existing = @($flowLogTemplate.resources.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { $_.PSObject.Properties.Name -contains 'existing' })
}

Describe 'Flow-log storage account (Phase 6)' {
    It 'disables shared key access, so writers must use Entra ID' {
        $account.properties.allowSharedKeyAccess | Should -BeExactly $false
        $account.properties.defaultToOAuthAuthentication | Should -BeExactly $true
    }

    It 'denies every network by default with no IP or VNet rules, letting only trusted Azure services through (final review M-4)' {
        # publicNetworkAccess Enabled keeps the firewall in force; Disabled would likely ignore the trusted-services bypass (ADR-023).
        $account.properties.publicNetworkAccess | Should -Be 'Enabled'
        $account.properties.networkAcls.defaultAction | Should -Be 'Deny'
        $account.properties.networkAcls.bypass | Should -Be 'AzureServices'
        @($account.properties.networkAcls.ipRules).Count | Should -Be 0
        @($account.properties.networkAcls.virtualNetworkRules).Count | Should -Be 0
    }

    It 'keeps the account hardening baseline (TLS 1.2, HTTPS only, no public blobs)' {
        $account.properties.minimumTlsVersion | Should -Be 'TLS1_2'
        $account.properties.supportsHttpsTrafficOnly | Should -BeExactly $true
        $account.properties.allowBlobPublicAccess | Should -BeExactly $false
    }

    It 'takes its redundancy from the caller' {
        $account.sku.name | Should -Be "[parameters('storageAccountSkuName')]"
    }
}

Describe 'Flow-log writer identity (Phase 6)' {
    It 'is a user-assigned managed identity in the same resource group' {
        $identity.name | Should -Be "[parameters('identityName')]"
        $identity.location | Should -Be "[parameters('location')]"
    }

    It 'gets Storage Blob Data Contributor on the flow-log account only' {
        $assignments.Count | Should -Be 1
        $assignment = $assignments[0]
        $storageTemplate.variables.storageBlobDataContributorRoleId | Should -Be 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        $assignment.scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
        $assignment.properties.principalType | Should -Be 'ServicePrincipal'
        $assignment.properties.principalId | Should -Match "userAssignedIdentities', parameters\('identityName'\)\), '2023-01-31'\)\.principalId\]$"
    }

    It 'outputs the account and identity IDs for the flow logs' {
        foreach ($output in 'id', 'identityId') {
            $storageTemplate.outputs.PSObject.Properties.Name | Should -Contain $output
        }
    }
}

Describe 'VNet flow logs (Phase 6)' {
    It 'uses the region''s existing NetworkWatcher_<region> as parent' {
        $watcher = $existing | Where-Object { $_.type -eq 'Microsoft.Network/networkWatchers' }
        $watcher.name | Should -Be "[format('NetworkWatcher_{0}', parameters('location'))]"
        $flowLog.name | Should -Match "^\[format\('\{0\}/\{1\}', format\('NetworkWatcher_\{0\}', parameters\('location'\)\)"
    }

    It 'logs every VNet passed in, one flow log each named after the VNet' {
        $flowLog.copy.count | Should -Be "[length(parameters('virtualNetworks'))]"
        $flowLog.name | Should -Match "format\('\{0\}-flowlog', parameters\('virtualNetworks'\)\[copyIndex\(\)\]\.name\)"
        $flowLog.properties.targetResourceId | Should -Be "[parameters('virtualNetworks')[copyIndex()].id]"
        $flowLog.properties.enabled | Should -BeExactly $true
    }

    It 'writes to the flow-log account with the user-assigned identity, not a key' {
        $flowLog.properties.storageId | Should -Be "[parameters('storageAccountId')]"
        $flowLog.identity.type | Should -Be 'UserAssigned'
        @($flowLog.identity.userAssignedIdentities.PSObject.Properties.Name) | Should -Be @("[format('{0}', parameters('identityId'))]")
    }

    It 'keeps 90 days of records in version 2 JSON' {
        $flowLogTemplate.parameters.retentionDays.defaultValue | Should -Be 90
        $flowLog.properties.retentionPolicy.enabled | Should -BeExactly $true
        $flowLog.properties.retentionPolicy.days | Should -Be "[parameters('retentionDays')]"
        $flowLog.properties.format.type | Should -Be 'JSON'
        $flowLog.properties.format.version | Should -Be 2
    }

    It 'sends Traffic Analytics to the central workspace every 10 minutes' {
        $analytics = $flowLog.properties.flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration
        $analytics.enabled | Should -BeExactly $true
        $analytics.workspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
        $analytics.workspaceId | Should -Match '\.customerId\]$'
        $analytics.workspaceRegion | Should -Match "'full'\)\.location\]$"
        $flowLogTemplate.parameters.trafficAnalyticsIntervalMinutes.defaultValue | Should -Be 10
        $analytics.trafficAnalyticsInterval | Should -Be "[parameters('trafficAnalyticsIntervalMinutes')]"
    }

    It 'pins the GA API version 2024-07-01 (identity support starts at 2024-01-01)' {
        $flowLog.apiVersion | Should -Be '2024-07-01'
    }
}
