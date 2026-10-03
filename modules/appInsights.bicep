@description('Azure region for the Application Insights component (the stamp region).')
param location string

@description('Application Insights component name.')
@minLength(1)
@maxLength(260)
param componentName string

@description('Central Log Analytics workspace resource ID; telemetry is stored there (workspace-based).')
param logAnalyticsWorkspaceId string

// Workspace-based, Entra ID-only ingestion: the App Service identity needs Monitoring Metrics Publisher (appInsightsPublisher.bicep).
// Public ingestion and query stay enabled until Phase 6 adds the Azure Monitor Private Link Scope (AMPLS).
resource component 'Microsoft.Insights/components@2020-02-02' = {
  name: componentName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output id string = component.id
output name string = component.name
output connectionString string = component.properties.ConnectionString
