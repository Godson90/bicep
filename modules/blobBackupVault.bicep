@description('Azure region for the Backup vault: the storage account\'s region.')
param location string

@description('Backup vault name.')
@minLength(2)
@maxLength(50)
param vaultName string

@description('Application storage account to protect, in this resource group.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Blob containers to protect with vaulted backup.')
@minLength(1)
param containerNames string[]

@description('Log Analytics workspace resource ID for the backup reporting tables.')
param logAnalyticsWorkspaceId string

@description('Apply a CanNotDelete lock to the vault.')
param enableDeleteLock bool = false

var storageAccountBackupContributorRoleId = 'e5e2a7ff-d759-4cd2-bb51-3152d37e2eb1'
var policyName = 'blob-daily-vaulted'
// Backup vaults send these resource-specific tables; AddonAzureBackupStorage does not apply to them.
var backupLogCategories = [
  'CoreAzureBackup'
  'AddonAzureBackupJobs'
  'AddonAzureBackupPolicy'
  'AddonAzureBackupProtectedInstance'
]
var vaultStore = {
  dataStoreType: 'VaultStore'
  objectType: 'DataStoreInfoBase'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
  name: storageAccountName
}

// Blob vaulted backup (Phase 8, ADR-031): an offsite, geo-redundant copy of the application containers. Only a
// system-assigned identity works for blobs. Blob vaulted backup has no cross-region restore, so the feature is off.
// Soft delete and immutability start reversible; AlwaysOn and Locked are runbook 08 steps after the first drill (ADR-030).
resource vault 'Microsoft.DataProtection/backupVaults@2026-06-01' = {
  name: vaultName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    storageSettings: [
      {
        datastoreType: 'VaultStore'
        type: 'GeoRedundant'
      }
    ]
    securitySettings: {
      softDeleteSettings: {
        state: 'On'
        retentionDurationInDays: 14
      }
      immutabilitySettings: {
        state: 'Unlocked'
      }
    }
    featureSettings: {
      crossRegionRestoreSettings: {
        state: 'Disabled'
      }
    }
    monitoringSettings: {
      azureMonitorAlertSettings: {
        alertsForAllJobFailures: 'Enabled'
      }
    }
  }
}

// Daily vaulted copy at 02:00 UTC, kept 30 days. Azure Backup cannot change a policy in place: a new schedule or
// retention needs a policy with a new name.
resource policy 'Microsoft.DataProtection/backupVaults/backupPolicies@2026-06-01' = {
  parent: vault
  name: policyName
  properties: {
    objectType: 'BackupPolicy'
    datasourceTypes: [
      'Microsoft.Storage/storageAccounts/blobServices'
    ]
    policyRules: [
      {
        name: 'BackupDaily'
        objectType: 'AzureBackupRule'
        backupParameters: {
          objectType: 'AzureBackupParams'
          backupType: 'Discrete'
        }
        dataStore: vaultStore
        trigger: {
          objectType: 'ScheduleBasedTriggerContext'
          schedule: {
            repeatingTimeIntervals: [
              'R/2026-01-01T02:00:00+00:00/P1D'
            ]
            timeZone: 'UTC'
          }
          taggingCriteria: [
            {
              isDefault: true
              taggingPriority: 99
              tagInfo: {
                tagName: 'Default'
              }
            }
          ]
        }
      }
      {
        name: 'Default'
        objectType: 'AzureRetentionRule'
        isDefault: true
        lifecycles: [
          {
            deleteAfter: {
              objectType: 'AbsoluteDeleteOption'
              duration: 'P30D'
            }
            sourceDataStore: vaultStore
            targetDataStoreCopySettings: []
          }
        ]
      }
    ]
  }
}

// The vault's identity sets up object replication from the account to the vault, so it needs this role on the
// account. The pipeline may assign it because the role is in its delegatable list (runbook 00b).
resource backupContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vault.id, storageAccountBackupContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: vault.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountBackupContributorRoleId)
  }
}

// Protection starts after the role assignment. A new assignment can take minutes to propagate; if the first deploy
// fails on permissions, rerun it (runbook 08).
resource instance 'Microsoft.DataProtection/backupVaults/backupInstances@2026-06-01' = {
  parent: vault
  name: storageAccountName
  properties: {
    objectType: 'BackupInstance'
    friendlyName: storageAccountName
    dataSourceInfo: {
      objectType: 'Datasource'
      datasourceType: 'Microsoft.Storage/storageAccounts/blobServices'
      resourceID: storageAccount.id
      resourceUri: storageAccount.id
      resourceName: storageAccountName
      resourceType: 'Microsoft.Storage/storageAccounts'
      resourceLocation: location
    }
    policyInfo: {
      policyId: policy.id
      policyParameters: {
        backupDatasourceParametersList: [
          {
            // The Azure Backup REST reference uses BlobBackupDatasourceParameters for explicit containers. The Bicep
            // types list only its Data Lake subtype (AdlsBlobBackupDatasourceParameters), which is for HNS accounts.
            #disable-next-line BCP036
            objectType: 'BlobBackupDatasourceParameters'
            containersList: containerNames
          }
        ]
      }
    }
  }
  dependsOn: [
    backupContributor
  ]
}

resource vaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vault
  name: 'bv-diagnostics'
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
