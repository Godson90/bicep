param location string 
param appServiceAppName string

@allowed(
  [
    'prod'
    'dev'
    'test'
  ]
)

param environmentType string // Parameters for different environment deployment
var appServicePlanName string = 'defenstack-product-plan'
var appServicePlanSkuName = (environmentType == 'prod') ? 'P2V3' : 'F1'

// App service plan creation
resource appServiceplan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: appServicePlanName
  location: location
  sku:{
    name: appServicePlanSkuName
    tier: 'Free'
  }
}

// App service app creation
resource appServiceApp 'Microsoft.Web/sites@2025-03-01' = {
  name: appServiceAppName
  location: location
  properties: {
    serverFarmId: appServiceplan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
  }
}
output appServiceAppHostName string = appServiceApp.properties.defaultHostName
