@description('Azure region for the vault. Azure VM backup needs the vault in the VM\'s region.')
param location string

@description('Recovery Services vault name.')
@minLength(2)
@maxLength(50)
param vaultName string

@description('Log Analytics workspace resource ID for the backup reporting tables.')
param logAnalyticsWorkspaceId string

@description('Resource ID of the VM to protect: the jump host, in the stamp where it exists. Empty creates the vault with no policy and no protected item.')
param virtualMachineId string = ''

@description('Apply a CanNotDelete lock to the vault.')
param enableDeleteLock bool = false

var protectVirtualMachine = !empty(virtualMachineId)
var policyName = 'vm-daily-enhanced'
// Azure Backup names an Azure VM's container and item after its resource group and name, under the fixed fabric Azure.
var virtualMachineName = last(split(virtualMachineId, '/'))
var virtualMachineResourceGroupName = empty(virtualMachineId) ? '' : split(virtualMachineId, '/')[4]
var protectionContainerName = 'iaasvmcontainer;iaasvmcontainerv2;${virtualMachineResourceGroupName};${virtualMachineName}'
var protectedItemName = 'vm;iaasvmcontainerv2;${virtualMachineResourceGroupName};${virtualMachineName}'
// The resource-specific tables Backup reports and runbook 08 query. AddonAzureBackupAlerts is omitted: it carries only
// the retired classic alerts.
var backupLogCategories = [
  'CoreAzureBackup'
  'AddonAzureBackupJobs'
  'AddonAzureBackupPolicy'
  'AddonAzureBackupStorage'
  'AddonAzureBackupProtectedInstance'
  'AzureBackupOperations'
]
// First run date for the schedule; Azure Backup uses only the time of day (02:00 UTC).
var dailyRunTime = '2026-01-01T02:00:00Z'

// One vault per stamp (Phase 8). Public network access stays Enabled, with no private endpoint, to keep cross-region
// restore: "Without a private connection in the secondary region, CRR can't perform the required replication"
// (https://learn.microsoft.com/azure/backup/backup-azure-backup-faq). Azure VM backup is snapshot-based and moves no
// data through the vault's network endpoint; access stays Entra/RBAC-authorised (ADR-033). Soft delete and
// immutability start reversible; AlwaysON soft delete and a Locked immutability state are runbook 08 steps after the
// first successful drill (ADR-030).
resource vault 'Microsoft.RecoveryServices/vaults@2026-07-01' = {
  name: vaultName
  location: location
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    securitySettings: {
      softDeleteSettings: {
        softDeleteState: 'Enabled'
        softDeleteRetentionPeriodInDays: 14
        enhancedSecurityState: 'Enabled'
      }
      immutabilitySettings: {
        state: 'Unlocked'
      }
    }
    monitoringSettings: {
      azureMonitorAlertSettings: {
        alertsForAllJobFailures: 'Enabled'
      }
      // Classic alerts are retired in favour of the Azure Monitor alerts above, which main.bicep routes to the
      // action group.
      classicAlertSettings: {
        alertsForCriticalOperations: 'Disabled'
        emailNotificationsForSiteRecovery: 'Disabled'
      }
    }
  }
}

// Geo-redundant backup storage with cross-region restore to the paired region. The setting locks once an item is
// registered, so it is written before any protected item. 2026-07-01 is the newest version with Bicep types.
resource storageConfig 'Microsoft.RecoveryServices/vaults/backupstorageconfig@2026-07-01' = {
  parent: vault
  name: 'vaultstorageconfig'
  properties: {
    storageModelType: 'GeoRedundant'
    crossRegionRestoreFlag: true
  }
}

// Enhanced policy: required for Trusted Launch VMs, with zone-redundant instant-restore snapshots.
resource policy 'Microsoft.RecoveryServices/vaults/backupPolicies@2026-07-01' = if (protectVirtualMachine) {
  parent: vault
  name: policyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V2'
    timeZone: 'UTC'
    instantRpRetentionRangeInDays: 7
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Daily'
      dailySchedule: {
        scheduleRunTimes: [
          dailyRunTime
        ]
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          dailyRunTime
        ]
        retentionDuration: {
          count: 30
          durationType: 'Days'
        }
      }
      weeklySchedule: {
        daysOfTheWeek: [
          'Sunday'
        ]
        retentionTimes: [
          dailyRunTime
        ]
        retentionDuration: {
          count: 12
          durationType: 'Weeks'
        }
      }
    }
  }
}

// Azure Backup discovers the container when the item is created. The fabric has no Bicep types, so the item takes its
// full name rather than a parent chain. Removing the item from this template does not stop protection: runbook 08
// stops it explicitly.
resource protectedItem 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2026-07-01' = if (protectVirtualMachine) {
  name: '${vault.name}/Azure/${protectionContainerName}/${protectedItemName}'
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    sourceResourceId: virtualMachineId
    policyId: policy.id
  }
  dependsOn: [
    storageConfig
  ]
}

// Backup reporting tables in the central workspace, resource-specific as Backup reports require.
resource vaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vault
  name: 'rsv-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [for category in backupLogCategories: {
      category: category
      enabled: true
    }]
  }
}

resource vaultLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: vault
  name: '${vaultName}-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

output id string = vault.id
output name string = vault.name
