@description('Azure region for the Key Vault.')
param location string

@description('Globally unique Key Vault name. Use only letters, numbers, and hyphens.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Tenant ID that owns the Key Vault.')
param tenantId string = tenant().tenantId

@description('Log Analytics workspace resource ID for Key Vault diagnostics.')
param logAnalyticsWorkspaceId string

@description('Number of days soft-deleted objects are retained.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Enable purge protection. Keep enabled for production workloads.')
param enablePurgeProtection bool = true

// RBAC-based vault with public access disabled; clients use its private endpoint.
resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection
    publicNetworkAccess: 'Disabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
  }
}

// Key Vault audit events are centralized with the other platform diagnostics.
resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'keyvault-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = keyVault.id
output name string = keyVault.name
output vaultUri string = keyVault.properties.vaultUri
