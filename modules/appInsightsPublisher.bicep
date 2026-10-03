// Lets an App Service identity send telemetry to a component whose local (key-based) authentication is disabled.

@description('Application Insights component name in this resource group.')
@minLength(1)
@maxLength(260)
param componentName string

@description('Principal ID of the App Service managed identity that publishes telemetry.')
param publisherPrincipalId string

@description('Name of the App Service that owns the identity, used to make the assignment GUID deterministic.')
@minLength(2)
@maxLength(60)
param publisherAppServiceName string

var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource component 'Microsoft.Insights/components@2020-02-02' existing = {
  name: componentName
}

resource publisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(component.id, publisherAppServiceName, monitoringMetricsPublisherRoleId)
  scope: component
  properties: {
    principalId: publisherPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
  }
}
