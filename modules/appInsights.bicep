@description('Azure region for the Application Insights component (the stamp region).')
param location string

@description('Application Insights component name.')
@minLength(1)
@maxLength(260)
param componentName string

@description('Central Log Analytics workspace resource ID; telemetry is stored there (workspace-based).')
param logAnalyticsWorkspaceId string

// Workspace-based, Entra ID-only ingestion: the App Service identity needs Monitoring Metrics Publisher (appInsightsPublisher.bicep).
// Ingestion and query go only through the Azure Monitor Private Link Scope; the entry point scopes this component into it (Phase 6).
resource component 'Microsoft.Insights/components@2020-02-02' = {
  name: componentName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

output id string = component.id
output name string = component.name
output connectionString string = component.properties.ConnectionString
