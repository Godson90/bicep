BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/recoveryServicesVault.bicep'
    $vault = Get-TemplateResource -Template $template -Type 'Microsoft.RecoveryServices/vaults' | Select-Object -First 1
    $storageConfig = Get-TemplateResource -Template $template -Type 'Microsoft.RecoveryServices/vaults/backupstorageconfig' | Select-Object -First 1
    $policy = Get-TemplateResource -Template $template -Type 'Microsoft.RecoveryServices/vaults/backupPolicies' | Select-Object -First 1
    $protectedItem = Get-TemplateResource -Template $template -Type 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems' | Select-Object -First 1
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
    $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
}

Describe 'Recovery Services vault (Phase 8)' {
    It 'pins the GA API version 2026-07-01 with the Standard SKU and a system-assigned identity' {
        $vault.apiVersion | Should -Be '2026-07-01'
        $vault.sku.name | Should -Be 'RS0'
        $vault.sku.tier | Should -Be 'Standard'
        $vault.identity.type | Should -Be 'SystemAssigned'
    }

    It 'denies public network access with no private endpoint; Azure VM backup does not need one (ADR-033)' {
        $vault.properties.publicNetworkAccess | Should -Be 'Disabled'
        Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateEndpoints' | Should -BeNullOrEmpty
    }

    It 'keeps soft delete Enabled for 14 days, never the irreversible AlwaysON (ADR-030)' {
        $softDelete = $vault.properties.securitySettings.softDeleteSettings
        $softDelete.softDeleteState | Should -BeExactly 'Enabled'
        $softDelete.softDeleteRetentionPeriodInDays | Should -Be 14
        $softDelete.enhancedSecurityState | Should -BeExactly 'Enabled'
        ($vault.properties | ConvertTo-Json -Depth 20) | Should -Not -Match 'AlwaysON'
    }

    It 'starts immutability Unlocked; locking is a runbook 08 step after the first drill (ADR-030)' {
        $vault.properties.securitySettings.immutabilitySettings.state | Should -BeExactly 'Unlocked'
    }

    It 'raises Azure Monitor alerts for every job failure and turns the classic alerts off' {
        $monitoring = $vault.properties.monitoringSettings
        $monitoring.azureMonitorAlertSettings.alertsForAllJobFailures | Should -Be 'Enabled'
        $monitoring.classicAlertSettings.alertsForCriticalOperations | Should -Be 'Disabled'
        $monitoring.classicAlertSettings.emailNotificationsForSiteRecovery | Should -Be 'Disabled'
    }
}

Describe 'Recovery Services vault storage (Phase 8)' {
    It 'stores backups geo-redundantly with cross-region restore, as the fixed child vaultstorageconfig' {
        $storageConfig.name | Should -Match "'vaultstorageconfig'\)\]$"
        $storageConfig.apiVersion | Should -Be '2026-07-01'
        $storageConfig.properties.storageModelType | Should -Be 'GeoRedundant'
        $storageConfig.properties.crossRegionRestoreFlag | Should -BeExactly $true
    }

    It 'sets storage before any protected item, since it locks once an item is registered' {
        @($protectedItem.dependsOn) | Should -Contain "[resourceId('Microsoft.RecoveryServices/vaults/backupstorageconfig', parameters('vaultName'), 'vaultstorageconfig')]"
    }
}

Describe 'Jump host backup (Phase 8)' {
    It 'protects nothing by default, so stamps without the jump host get an empty vault' {
        $template.parameters.virtualMachineId.defaultValue | Should -BeExactly ''
        $template.variables.protectVirtualMachine | Should -Be "[not(empty(parameters('virtualMachineId')))]"
        $policy.condition | Should -Be "[variables('protectVirtualMachine')]"
        $protectedItem.condition | Should -Be "[variables('protectVirtualMachine')]"
    }

    It 'uses an Enhanced (V2) Azure VM policy in UTC, which Trusted Launch VMs require' {
        $policy.properties.backupManagementType | Should -Be 'AzureIaasVM'
        $policy.properties.policyType | Should -Be 'V2'
        $policy.properties.timeZone | Should -Be 'UTC'
    }

    It 'backs up daily at 02:00 UTC and keeps 7 days of instant-restore snapshots' {
        $schedule = $policy.properties.schedulePolicy
        $schedule.schedulePolicyType | Should -Be 'SimpleSchedulePolicyV2'
        $schedule.scheduleRunFrequency | Should -Be 'Daily'
        $template.variables.dailyRunTime | Should -Be '2026-01-01T02:00:00Z'
        @($schedule.dailySchedule.scheduleRunTimes) | Should -Be @("[variables('dailyRunTime')]")
        @($policy.properties.retentionPolicy.dailySchedule.retentionTimes) | Should -Be @("[variables('dailyRunTime')]")
        @($policy.properties.retentionPolicy.weeklySchedule.retentionTimes) | Should -Be @("[variables('dailyRunTime')]")
        $policy.properties.instantRpRetentionRangeInDays | Should -Be 7
    }

    It 'keeps 30 daily and 12 weekly (Sunday) recovery points' {
        $retention = $policy.properties.retentionPolicy
        $retention.retentionPolicyType | Should -Be 'LongTermRetentionPolicy'
        $retention.dailySchedule.retentionDuration.count | Should -Be 30
        $retention.dailySchedule.retentionDuration.durationType | Should -Be 'Days'
        $retention.weeklySchedule.retentionDuration.count | Should -Be 12
        $retention.weeklySchedule.retentionDuration.durationType | Should -Be 'Weeks'
        @($retention.weeklySchedule.daysOfTheWeek) | Should -Be @('Sunday')
    }

    It 'names the container and item iaasvmcontainerv2;<rg>;<vm> under the Azure fabric' {
        $template.variables.protectionContainerName | Should -Be "[format('iaasvmcontainer;iaasvmcontainerv2;{0};{1}', variables('virtualMachineResourceGroupName'), variables('virtualMachineName'))]"
        $template.variables.protectedItemName | Should -Be "[format('vm;iaasvmcontainerv2;{0};{1}', variables('virtualMachineResourceGroupName'), variables('virtualMachineName'))]"
        $protectedItem.name | Should -Be "[format('{0}/Azure/{1}/{2}', parameters('vaultName'), variables('protectionContainerName'), variables('protectedItemName'))]"
    }

    It 'reads the VM name and resource group from the VM resource ID' {
        $template.variables.virtualMachineName | Should -Be "[last(split(parameters('virtualMachineId'), '/'))]"
        $template.variables.virtualMachineResourceGroupName | Should -Be "[if(empty(parameters('virtualMachineId')), '', split(parameters('virtualMachineId'), '/')[4])]"
    }

    It 'protects the VM with the policy' {
        $protectedItem.properties.protectedItemType | Should -Be 'Microsoft.Compute/virtualMachines'
        $protectedItem.properties.sourceResourceId | Should -Be "[parameters('virtualMachineId')]"
        $protectedItem.properties.policyId | Should -Be "[resourceId('Microsoft.RecoveryServices/vaults/backupPolicies', parameters('vaultName'), variables('policyName'))]"
        @($protectedItem.dependsOn) | Should -Contain "[resourceId('Microsoft.RecoveryServices/vaults/backupPolicies', parameters('vaultName'), variables('policyName'))]"
    }
}

Describe 'Recovery Services vault operations (Phase 8)' {
    It 'sends the resource-specific backup tables to the central workspace, without the classic alert table' {
        $diagnostics.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
        $diagnostics.properties.logAnalyticsDestinationType | Should -Be 'Dedicated'
        $diagnostics.properties.copy[0].count | Should -Be "[length(variables('backupLogCategories'))]"
        @($template.variables.backupLogCategories) -join ',' |
            Should -Be 'CoreAzureBackup,AddonAzureBackupJobs,AddonAzureBackupPolicy,AddonAzureBackupStorage,AddonAzureBackupProtectedInstance,AzureBackupOperations'
    }

    It 'locks the vault only when requested' {
        $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
        $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
        $lock.properties.level | Should -Be 'CanNotDelete'
        $lock.name | Should -Be "[format('{0}-lck', parameters('vaultName'))]"
    }

    It 'outputs the vault ID and name for the alert processing rule and runbook 08' {
        $template.outputs.id.value | Should -Match 'Microsoft\.RecoveryServices/vaults'
        $template.outputs.name.value | Should -Be "[parameters('vaultName')]"
    }
}

Describe 'Recovery Services vault PSRule exclusion (Phase 8)' {
    It 'excludes only the Site Recovery replication-alert rule, citing ADR-030; Azure Backup alerts go through Azure Monitor' {
        $text = Get-Content (Get-RepoPath 'ps-rule.yaml') -Raw
        $text | Should -Match '# ADR-030:[^\r\n]*\r?\n\s*- Azure\.RSV\.ReplicationAlert'
        Get-TemplateResource -Template $template -Type 'Microsoft.RecoveryServices/vaults/replicationAlertSettings' | Should -BeNullOrEmpty
    }
}
