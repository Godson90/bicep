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

@description('Allow Azure Resource Manager to retrieve secrets during deployments, required for az.getSecret() in .bicepparam files. Keep false for vaults that never back deployment parameters.')
param enabledForTemplateDeployment bool = false

@description('Apply a CanNotDelete lock to the vault (in addition to soft delete and purge protection).')
param enableDeleteLock bool = false

@description('Application secrets to write, as { name: value }. Written through Azure Resource Manager, so the deploying identity needs no network path to the private vault (ADR-019). Names: letters, digits and hyphens, at most 127 characters.')
@secure()
param secrets object = {}

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
    enabledForTemplateDeployment: enabledForTemplateDeployment
    publicNetworkAccess: 'Disabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
    networkAcls: {
      bypass: enabledForTemplateDeployment ? 'AzureServices' : 'None'
      defaultAction: 'Deny'
    }
  }
}

// The same deploy-time values go to every regional vault, which is how the stamps stay in sync (ADR-019).
resource vaultSecrets 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = [for secret in items(secrets): {
  parent: keyVault
  name: secret.key
  properties: {
    value: secret.value
    attributes: {
      enabled: true
    }
  }
}]

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

resource keyVaultLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: keyVault
  name: '${keyVaultName}-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

output id string = keyVault.id
output name string = keyVault.name
output vaultUri string = keyVault.properties.vaultUri
