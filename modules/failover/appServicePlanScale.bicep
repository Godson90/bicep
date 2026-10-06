// Scales the warm-standby App Service plan to prod capacity during a declared outage (Phase 8, runbook 08). It
// re-states the plan exactly as appService.bicep created it, changing only the instance count, so the application
// is not redeployed. The East US plan was created without zone redundancy, which cannot change after creation.

@description('Azure region of the existing plan.')
param location string

@description('Name of the existing App Service plan.')
@minLength(1)
@maxLength(60)
param appServicePlanName string

@description('Instance count during the failover.')
@minValue(1)
@maxValue(30)
param capacity int

resource appServicePlan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: appServicePlanName
  location: location
  // The prod SKU from appService.bicep; a test pins the parity.
  sku: {
    name: 'P2V3'
    tier: 'PremiumV3'
    capacity: capacity
  }
  properties: {
    zoneRedundant: false
  }
}

output name string = appServicePlan.name
