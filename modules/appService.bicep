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
    }
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
