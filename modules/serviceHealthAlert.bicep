@description('Alert rule name.')
param alertName string

@description('Regions to watch, as Service Health names them (for example West US 3), plus Global for non-regional events.')
param regions string[]

@description('Resource ID of the action group notified when Service Health reports an event.')
param actionGroupId string

// Service Health incidents, planned maintenance and advisories for the platform regions (Phase 6). Activity log
// alerts are global and watch the whole subscription; 2020-10-01 is the GA version (research §6).
resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: alertName
  location: 'Global'
  properties: {
    description: 'Azure Service Health event affecting a DefenStack region. Triage: runbook 06.'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          anyOf: [
            {
              field: 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
              containsAny: regions
            }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

output name string = serviceHealthAlert.name
