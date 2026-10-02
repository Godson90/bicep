@description('Azure region for the App Service plan and application.')
param location string

@description('Globally unique App Service application name.')
@minLength(2)
@maxLength(60)
param appServiceAppName string

@description('Delegated subnet resource ID used for App Service regional VNet integration.')
param vnetIntegrationSubnetId string = ''

@description('Log Analytics workspace resource ID for App Service diagnostics.')
param logAnalyticsWorkspaceId string

@allowed(
  [
    'prod'
    'dev'
    'test'
  ]
)

@description('Deployment environment that controls App Service plan sizing.')
param environmentType string

@description('Relative path probed by App Service health check; it must return 200-299 when the instance is healthy.')
param healthCheckPath string = '/'

@description('Spread plan instances across availability zones. Zone redundancy is set when a plan is created, so enable it only for new plans.')
param zoneRedundant bool = false

@description('Number of plan instances. Zone-redundant plans require at least 3.')
@minValue(1)
@maxValue(30)
param instanceCount int = 1

@description('Application Insights connection string for this region. Empty sends no telemetry.')
param applicationInsightsConnectionString string = ''

@description('App Service plan name. Include the environment and region so every stamp gets its own plan.')
@minLength(1)
@maxLength(60)
param appServicePlanName string

var appServicePlanSkuName = (environmentType == 'prod') ? 'P2V3' : 'S1'
var appServicePlanSkuTier = (environmentType == 'prod') ? 'PremiumV3' : 'Standard'
// Entra ID (managed identity) telemetry authentication; the component disables key-based ingestion.
var telemetrySettings = empty(applicationInsightsConnectionString) ? [] : [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: applicationInsightsConnectionString
  }
  {
    name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
    value: 'Authorization=AAD'
  }
]

// App service plan creation
// Environment-specific plan capacity for the private, VNet-integrated application.
resource appServiceplan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServicePlanSkuName
    tier: appServicePlanSkuTier
    capacity: instanceCount
  }
  properties: {
    zoneRedundant: zoneRedundant
  }
}

// App service app creation
// Private App Service with managed identity, HTTPS-only access, and route-all enabled.
resource appServiceApp 'Microsoft.Web/sites@2025-03-01' = {
  name: appServiceAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServiceplan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    clientAffinityEnabled: false
    virtualNetworkSubnetId: empty(vnetIntegrationSubnetId) ? null : vnetIntegrationSubnetId
    siteConfig: {
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      alwaysOn: true
      healthCheckPath: healthCheckPath
      scmMinTlsVersion: '1.2'
      remoteDebuggingEnabled: false
      // Public access is disabled; default-deny keeps the site and Kudu closed even if it is ever re-enabled.
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      appSettings: telemetrySettings
    }
  }
}

// Basic (username/password) publishing is disabled; deployments use Entra ID tokens.
resource ftpBasicPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: appServiceApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmBasicPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: appServiceApp
  name: 'scm'
  properties: {
    allow: false
  }
}

// Application platform and request telemetry are sent to the central workspace.
resource appServiceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: appServiceApp
  name: 'appservice-diagnostics'
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

output appServiceAppHostName string = appServiceApp.properties.defaultHostName
output appServiceAppId string = appServiceApp.id
output appServicePrincipalId string = appServiceApp.identity.principalId
