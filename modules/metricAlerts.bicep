import { metricAlertRule } from 'types.bicep'

@description('Prefix of every alert name, for example alert-defenstack-prod-wus3.')
param namePrefix string

@description('Static-threshold metric alerts to create, each on one resource.')
param rules metricAlertRule[]

@description('Resource ID of the action group notified when an alert fires or resolves.')
param actionGroupId string

// Static-threshold metric alerts (Phase 6). 2018-03-01 is the last clearly GA metricAlerts API version (research §6).
// Every rule is evaluated every 5 minutes over a 15-minute window and resolves itself when the metric recovers.
resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for rule in rules: if (rule.?deploy ?? true) {
  name: '${namePrefix}-${rule.name}'
  location: 'global'
  properties: {
    description: rule.description
    severity: rule.severity
    enabled: true
    scopes: [
      rule.resourceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: rule.name
          metricNamespace: rule.metricNamespace
          metricName: rule.metricName
          operator: rule.operator
          // Bicep has no decimal literals, so thresholds arrive as text (for example '99.9').
          threshold: json(rule.threshold)
          timeAggregation: rule.timeAggregation
          dimensions: rule.?dimensions ?? []
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}]
