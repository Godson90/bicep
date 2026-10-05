// Exempts one region's flow-log storage account from the storage public network access assignment (Phase 7).
// The account keeps public network access Enabled behind a deny-all firewall, so Network Watcher can write to it
// as a trusted Azure service (ADR-023). Deployed into the regional resource group; the account must already exist.

@description('Environment of the stamp that owns the account.')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Full region name of the stamp, for example westus3. It is part of the account name hash.')
param location string

@description('Short region code of the stamp, for example wus3.')
@minLength(2)
@maxLength(4)
param regionCode string

@description('Resource ID of the storage public network access assignment.')
param policyAssignmentId string

// The same formula as regionStamp.bicep (nameSuffix and names.flowLogStorageAccount); a test pins the parity.
var nameSuffix = uniqueString(subscription().id, environmentName, location)
var flowLogStorageAccountName = 'stfl${regionCode}${nameSuffix}'

resource flowLogStorage 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
  name: flowLogStorageAccountName
}

// Microsoft.Authorization/policyExemptions has no GA API version; 2026-01-01-preview is the latest (ADR-029).
resource exemption 'Microsoft.Authorization/policyExemptions@2026-01-01-preview' = {
  name: 'defenstack-flow-log-storage-public-network'
  scope: flowLogStorage
  properties: {
    policyAssignmentId: policyAssignmentId
    exemptionCategory: 'Mitigated'
    displayName: 'Flow-log storage: deny-all firewall instead of disabled public access'
    description: 'Network Watcher writes VNet flow logs as a trusted Azure service. Public network access stays Enabled so the deny-all firewall and its trusted-services bypass apply; shared key is disabled (ADR-023).'
  }
}

// Only Network Watcher's identity writes here, and on-upload scanning would rescan each hourly flow-log blob on every
// block commit: malware scanning and sensitive data discovery are off, activity monitoring stays on (ADR-026).
resource flowLogDefenderSettings 'Microsoft.Security/defenderForStorageSettings@2025-01-01' = {
  name: 'current'
  scope: flowLogStorage
  properties: {
    isEnabled: true
    overrideSubscriptionLevelSettings: true
    malwareScanning: {
      onUpload: {
        isEnabled: false
      }
    }
    sensitiveDataDiscovery: {
      isEnabled: false
    }
  }
}

output storageAccountName string = flowLogStorage.name
