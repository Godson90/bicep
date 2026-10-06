// Regional failover (Phase 8): brings the prod East US warm standby up to primary strength during a declared West US 3
// outage. An operator deploys it with az deployment sub create (runbook 08); main.bicep and the pipeline never do, and
// the pipeline stays frozen until failback, since a pipeline run would undo these changes (ADR-032).
//
// It deploys into the East US resource group only. It reads the shared private DNS zones, the workspace and the AMPLS
// from the global resource group, and the endpoints' zone groups write records into those zones. Nothing here targets
// the West US 3 resource group: West US 3 appears only in the resource ID of the primary storage account, which the
// East US blob endpoint connects to. Tests pin both.
targetScope = 'subscription'

@description('Environment that fails over. Only prod has a warm standby.')
@allowed([
  'prod'
])
param environmentName string = 'prod'

@description('Region that takes over: the warm-standby region.')
@allowed([
  'eastus'
])
param location string = 'eastus'

@description('Instance count for the East US App Service plan during the failover. 3 matches the prod primary plan.')
@minValue(1)
@maxValue(30)
param appServicePlanCapacity int = 3

@description('Resource ID of the prod primary app storage account, which the East US blob endpoint connects to. The default names it as main.bicep and regionStamp.bicep do (rg-defenstack-<env>-wus3, st<code><nameSuffix>); a test pins the parity.')
param primaryStorageAccountId string = resourceId(
  subscription().subscriptionId,
  'rg-defenstack-${environmentName}-wus3',
  'Microsoft.Storage/storageAccounts',
  'stwus3${uniqueString(subscription().id, environmentName, 'westus3')}'
)

@description('Confirms a declared outage. False deploys nothing, so a stray run outside DR changes nothing.')
param failoverActive bool = true

// The same region code and shared zone names as main.bicep; tests pin the parity.
var regionCode = 'eus'
var resourceGroupName = 'rg-defenstack-${environmentName}-${regionCode}'
var globalResourceGroupName = 'rg-defenstack-${environmentName}-global'
var privateDnsZoneNames = {
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  sites: 'privatelink.azurewebsites.net'
  vault: 'privatelink.vaultcore.azure.net'
  monitor: 'privatelink.monitor.azure.com'
  oms: 'privatelink.oms.opinsights.azure.com'
  ods: 'privatelink.ods.opinsights.azure.com'
  agentsvc: 'privatelink.agentsvc.azure-automation.net'
}
// Named as regionStamp.bicep names them in the East US stamp.
var names = {
  appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
  bastion: 'bas-defenstack-${environmentName}-${regionCode}'
  bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
  hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
  spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
  amplsAsg: 'vnet-defenstack-${environmentName}-${regionCode}-spoke-ampls-asg'
  monitorPrivateEndpoint: 'ampls-defenstack-${environmentName}-${regionCode}-pe'
  // Distinct from the account's own <account>-pe (West US 3) and the standby's <account>-secondary-pe (blob_secondary).
  storagePrivateEndpoint: '${last(split(primaryStorageAccountId, '/'))}-${regionCode}-pe'
}

// Existing resources from main.bicep: the East US hub and spoke, and the shared layer in the global resource group.
resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
  name: names.hubVnet
  scope: resourceGroup(resourceGroupName)

  resource bastionSubnet 'subnets' existing = {
    name: 'AzureBastionSubnet'
  }
}

resource spokeVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
  name: names.spokeVnet
  scope: resourceGroup(resourceGroupName)

  resource privateEndpointSubnet 'subnets' existing = {
    name: 'private-endpoints'
  }
}

resource amplsAsg 'Microsoft.Network/applicationSecurityGroups@2024-07-01' existing = {
  name: names.amplsAsg
  scope: resourceGroup(resourceGroupName)
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
  name: 'log-defenstack-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
}

resource privateLinkScope 'Microsoft.Insights/privateLinkScopes@2021-09-01' existing = {
  name: 'ampls-defenstack-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
}

// a. The warm-standby plan runs at primary capacity. Same name, SKU and tier; only the instance count changes.
module appServicePlanScale 'modules/failover/appServicePlanScale.bicep' = if (failoverActive) {
  name: 'failover-app-service-plan-${regionCode}'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    appServicePlanName: names.appServicePlan
    capacity: appServicePlanCapacity
  }
}

// b. Admin access in East US for the restored jump host (runbook 08). The hub's AzureBastionSubnet exists from Phase 1,
// and governance.bicep already allows the pip-bas-…-eus public IP. The VPN gateway is not deployed: it takes too long
// for the one-hour RTO.
module bastion 'modules/bastion.bicep' = if (failoverActive) {
  name: 'failover-bastion-${regionCode}'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    bastionName: names.bastion
    publicIpName: names.bastionPublicIp
    subnetId: hubVnet::bastionSubnet.id
    availabilityZones: [
      '1'
      '2'
      '3'
    ]
    logAnalyticsWorkspaceId: workspace.id
  }
}

// c. A second Azure Monitor endpoint in the East US spoke. Its zone group overwrites the shared Azure Monitor records,
// so every VNet resolves the scope to East US. Failback deletes it and redeploys the primary endpoint (runbook 08).
module monitorPrivateEndpoint 'modules/monitorPrivateEndpoint.bicep' = if (failoverActive) {
  name: 'failover-monitor-private-endpoint-${regionCode}'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    privateLinkScopeId: privateLinkScope.id
    privateLinkScopeName: privateLinkScope.name
    privateEndpointName: names.monitorPrivateEndpoint
    privateEndpointSubnetId: spokeVnet::privateEndpointSubnet.id
    privateDnsZoneIds: toObject(
      items(privateDnsZoneNames),
      zone => zone.key,
      zone => resourceId(subscription().subscriptionId, globalResourceGroupName, 'Microsoft.Network/privateDnsZones', zone.value)
    )
    applicationSecurityGroupId: amplsAsg.id
  }
}

// d. Blob writes from East US. The account's own endpoint sits in the unreachable West US 3 spoke, so this endpoint in
// the East US spoke reaches the account once it has failed over. Its zone group overwrites the account's record in the
// shared blob zone; failback deletes it and the next pipeline deploy restores the West US 3 record (runbook 08). The
// write role stays a manual, PIM-gated runbook step, so the standby is read-only outside DR (ADR-020, ADR-032).
module storagePrivateEndpoint 'modules/failover/storagePrivateEndpoint.bicep' = if (failoverActive) {
  name: 'failover-storage-private-endpoint-${regionCode}'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    storageAccountId: primaryStorageAccountId
    privateEndpointName: names.storagePrivateEndpoint
    privateEndpointSubnetId: spokeVnet::privateEndpointSubnet.id
    blobPrivateDnsZoneId: resourceId(
      subscription().subscriptionId,
      globalResourceGroupName,
      'Microsoft.Network/privateDnsZones',
      privateDnsZoneNames.blob
    )
  }
}

output resourceGroupName string = resourceGroupName
output appServicePlanName string = failoverActive ? names.appServicePlan : ''
output bastionName string = failoverActive ? names.bastion : ''
output monitorPrivateEndpointId string = failoverActive ? monitorPrivateEndpoint!.outputs.id : ''
output storagePrivateEndpointId string = failoverActive ? storagePrivateEndpoint!.outputs.id : ''
