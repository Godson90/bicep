BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/blobBackupVault.bicep'
    $vault = Get-TemplateResource -Template $template -Type 'Microsoft.DataProtection/backupVaults' | Select-Object -First 1
    $policy = Get-TemplateResource -Template $template -Type 'Microsoft.DataProtection/backupVaults/backupPolicies' | Select-Object -First 1
    $instance = Get-TemplateResource -Template $template -Type 'Microsoft.DataProtection/backupVaults/backupInstances' | Select-Object -First 1
    $roleAssignment = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
    $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
    $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
}

Describe 'Backup vault for blob vaulted backup (Phase 8)' {
    It 'pins the GA API version 2026-06-01 with a system-assigned identity only (no user-assigned identity for blobs)' {
        $vault.apiVersion | Should -Be '2026-06-01'
        $vault.identity.type | Should -BeExactly 'SystemAssigned'
        $vault.identity.PSObject.Properties.Name | Should -Not -Contain 'userAssignedIdentities'
    }

    It 'keeps the vault store geo-redundant' {
        @($vault.properties.storageSettings).Count | Should -Be 1
        $vault.properties.storageSettings[0].datastoreType | Should -Be 'VaultStore'
        $vault.properties.storageSettings[0].type | Should -Be 'GeoRedundant'
    }

    It 'keeps soft delete On for 14 days, never AlwaysOn, and immutability Unlocked (ADR-030)' {
        $security = $vault.properties.securitySettings
        $security.softDeleteSettings.state | Should -BeExactly 'On'
        $security.softDeleteSettings.retentionDurationInDays | Should -Be 14
        $security.immutabilitySettings.state | Should -BeExactly 'Unlocked'
    }

    It 'turns cross-region restore off, since blob vaulted backup does not support it (ADR-031)' {
        $vault.properties.featureSettings.crossRegionRestoreSettings.state | Should -Be 'Disabled'
    }

    It 'raises Azure Monitor alerts for every job failure' {
        $vault.properties.monitoringSettings.azureMonitorAlertSettings.alertsForAllJobFailures | Should -Be 'Enabled'
    }

    It 'sends the resource-specific backup tables a Backup vault supports to the central workspace' {
        $diagnostics.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
        $diagnostics.properties.logAnalyticsDestinationType | Should -Be 'Dedicated'
        $diagnostics.properties.copy[0].count | Should -Be "[length(variables('backupLogCategories'))]"
        @($template.variables.backupLogCategories) -join ',' |
            Should -Be 'CoreAzureBackup,AddonAzureBackupJobs,AddonAzureBackupPolicy,AddonAzureBackupProtectedInstance'
    }

    It 'locks the vault only when requested' {
        $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
        $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
        $lock.properties.level | Should -Be 'CanNotDelete'
        $lock.name | Should -Be "[format('{0}-lck', parameters('vaultName'))]"
    }

    It 'outputs the vault ID and name for the alert processing rule and runbook 08' {
        $template.outputs.id.value | Should -Match 'Microsoft\.DataProtection/backupVaults'
        $template.outputs.name.value | Should -Be "[parameters('vaultName')]"
    }
}

Describe 'Blob vaulted backup policy (Phase 8)' {
    BeforeAll {
        $rules = @($policy.properties.policyRules)
        $backupRule = $rules | Where-Object { $_.objectType -eq 'AzureBackupRule' }
        $retentionRule = $rules | Where-Object { $_.objectType -eq 'AzureRetentionRule' }
    }

    It 'protects blob services' {
        $policy.apiVersion | Should -Be '2026-06-01'
        $policy.properties.objectType | Should -Be 'BackupPolicy'
        @($policy.properties.datasourceTypes) | Should -Be @('Microsoft.Storage/storageAccounts/blobServices')
        $rules.Count | Should -Be 2
    }

    It 'takes a discrete vaulted backup daily at 02:00 UTC' {
        $backupRule.name | Should -Be 'BackupDaily'
        $backupRule.backupParameters.objectType | Should -Be 'AzureBackupParams'
        $backupRule.backupParameters.backupType | Should -Be 'Discrete'
        $template.variables.vaultStore.dataStoreType | Should -Be 'VaultStore'
        $template.variables.vaultStore.objectType | Should -Be 'DataStoreInfoBase'
        $backupRule.dataStore | Should -Be "[variables('vaultStore')]"
        $backupRule.trigger.objectType | Should -Be 'ScheduleBasedTriggerContext'
        @($backupRule.trigger.schedule.repeatingTimeIntervals) | Should -Be @('R/2026-01-01T02:00:00+00:00/P1D')
        $backupRule.trigger.schedule.timeZone | Should -Be 'UTC'
        $backupRule.trigger.taggingCriteria[0].isDefault | Should -BeTrue
        $backupRule.trigger.taggingCriteria[0].tagInfo.tagName | Should -Be 'Default'
    }

    It 'keeps vaulted recovery points for 30 days' {
        $retentionRule.name | Should -Be 'Default'
        $retentionRule.isDefault | Should -BeTrue
        $retentionRule.lifecycles[0].deleteAfter.objectType | Should -Be 'AbsoluteDeleteOption'
        $retentionRule.lifecycles[0].deleteAfter.duration | Should -Be 'P30D'
        $retentionRule.lifecycles[0].sourceDataStore | Should -Be "[variables('vaultStore')]"
    }
}

Describe 'Blob backup permission and instance (Phase 8)' {
    It 'grants the vault Storage Account Backup Contributor on the application account only, with a deterministic name' {
        $template.variables.storageAccountBackupContributorRoleId | Should -Be 'e5e2a7ff-d759-4cd2-bb51-3152d37e2eb1'
        $roleAssignment.scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
        $roleAssignment.name | Should -Be "[guid(resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName')), resourceId('Microsoft.DataProtection/backupVaults', parameters('vaultName')), variables('storageAccountBackupContributorRoleId'))]"
        $roleAssignment.properties.principalId | Should -Be "[reference('vault', '2026-06-01', 'full').identity.principalId]"
        $roleAssignment.properties.principalType | Should -Be 'ServicePrincipal'
        $roleAssignment.properties.roleDefinitionId | Should -Be "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', variables('storageAccountBackupContributorRoleId'))]"
    }

    It 'protects the application account''s listed containers with the policy' {
        $source = $instance.properties.dataSourceInfo
        $source.objectType | Should -Be 'Datasource'
        $source.datasourceType | Should -Be 'Microsoft.Storage/storageAccounts/blobServices'
        $source.resourceType | Should -Be 'Microsoft.Storage/storageAccounts'
        $source.resourceID | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
        $source.resourceName | Should -Be "[parameters('storageAccountName')]"
        $instance.properties.policyInfo.policyId | Should -Be "[resourceId('Microsoft.DataProtection/backupVaults/backupPolicies', parameters('vaultName'), variables('policyName'))]"
    }

    It 'selects containers with BlobBackupDatasourceParameters, the documented type for blob vaulted backup (Adls… is for Data Lake accounts)' {
        $parameters = @($instance.properties.policyInfo.policyParameters.backupDatasourceParametersList)
        $parameters.Count | Should -Be 1
        $parameters[0].objectType | Should -BeExactly 'BlobBackupDatasourceParameters'
        $parameters[0].containersList | Should -Be "[parameters('containerNames')]"
        $template.parameters.containerNames.minLength | Should -Be 1
    }

    It 'creates the instance after the role assignment, which it needs to set up object replication' {
        @($instance.dependsOn) | Should -Contain 'backupContributor'
    }
}

Describe 'Region stamp blob vaulted backup (Phase 8)' {
    BeforeAll {
        $blobBackup = Get-ModuleDeployment -Template $stamp -Name 'blob-backup-vault'
        $blobBackupParameters = $blobBackup.properties.parameters
    }

    It 'is on by default only in the prod primary stamp, where the account is RA-GZRS (enableBlobVaultedBackup)' {
        $stamp.parameters.enableBlobVaultedBackup.type | Should -Be 'bool'
        $stamp.parameters.enableBlobVaultedBackup.defaultValue | Should -Be "[and(equals(parameters('environmentName'), 'prod'), equals(parameters('regionRole'), 'primary'))]"
        $blobBackup.condition | Should -Be "[parameters('enableBlobVaultedBackup')]"
    }

    It 'names the vault bv-defenstack-<env>-<region> and locks it in prod' {
        $stamp.variables.names.backupVault | Should -Be "[format('bv-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
        $blobBackupParameters.vaultName.value | Should -Be "[variables('names').backupVault]"
        $blobBackupParameters.enableDeleteLock.value | Should -Be "[variables('isProd')]"
        $blobBackupParameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
    }

    It 'protects the stamp''s application account and the container from the storage module' {
        $blobBackupParameters.storageAccountName.value | Should -Be "[reference('storage').outputs.name.value]"
        @($blobBackupParameters.containerNames.value) | Should -Be @("[reference('storage').outputs.blobContainerName.value]")
    }

    It 'outputs the Backup vault ID and name, empty where the vault is not deployed' {
        $stamp.outputs.backupVaultId.value | Should -Be "[if(parameters('enableBlobVaultedBackup'), reference('blobBackupVault').outputs.id.value, '')]"
        $stamp.outputs.backupVaultName.value | Should -Be "[if(parameters('enableBlobVaultedBackup'), variables('names').backupVault, '')]"
    }
}
