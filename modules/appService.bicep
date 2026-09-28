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

var appServicePlanName string = 'defenstack-${environmentType}-plan'
var appServicePlanSkuName = (environmentType == 'prod') ? 'P2V3' : 'S1'
var appServicePlanSkuTier = (environmentType == 'prod') ? 'PremiumV3' : 'Standard'

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
