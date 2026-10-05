targetScope = 'subscription'

@description('Name of the subscription diagnostic setting. Include the environment, since dev and prod may share a subscription.')
@minLength(1)
@maxLength(260)
param settingName string

@description('Resource ID of the Log Analytics workspace that receives the Activity Log.')
param logAnalyticsWorkspaceId string

// The subscription Activity Log feeds Sentinel's Azure Activity data (Phase 6). 2021-05-01-preview is the only API
// version that supports subscription-scope diagnostic settings (ADR-025). Diagnostic settings write over Azure's
// internal path, so the workspace's private-only ingestion does not block them. The Activity Log has no category
// groups, so every category is listed.
resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'Administrative', enabled: true }
      { category: 'Security', enabled: true }
      { category: 'ServiceHealth', enabled: true }
      { category: 'Alert', enabled: true }
      { category: 'Recommendation', enabled: true }
      { category: 'Policy', enabled: true }
      { category: 'Autoscale', enabled: true }
      { category: 'ResourceHealth', enabled: true }
    ]
  }
}

output name string = activityLog.name
