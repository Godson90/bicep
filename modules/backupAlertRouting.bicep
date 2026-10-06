@description('Alert processing rule name.')
param ruleName string

@description('Resource IDs the rule covers: the resource groups holding the Recovery Services and Backup vaults.')
@minLength(1)
param scopes array

@description('Resource ID of the environment\'s action group, which receives every Azure Backup alert.')
param actionGroupId string

// Azure Backup raises built-in Azure Monitor alerts (job failures, security events) with no action group of their
// own. This rule adds the environment's action group to every Azure Backup alert in the scopes (Phase 8). Alert
// processing rules have no kind property; 2021-08-08 is the GA version.
resource backupAlertRouting 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: ruleName
  location: 'global'
  properties: {
    description: 'Routes Azure Backup alerts from the DefenStack vaults to the platform action group. Triage: runbook 08.'
    enabled: true
    scopes: scopes
    conditions: [
      {
        field: 'MonitorService'
        operator: 'Equals'
        values: [
          'Azure Backup'
        ]
      }
    ]
    actions: [
      {
        actionType: 'AddActionGroups'
        actionGroupIds: [
          actionGroupId
        ]
      }
    ]
  }
}

output id string = backupAlertRouting.id
output name string = backupAlertRouting.name
