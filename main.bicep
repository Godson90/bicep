targetScope = 'subscription'

import { regionAddressPlan, privateDnsZoneSet } from 'modules/types.bicep'

@description('Deployment environment. Selects resource group names, redundancy, and deletion protection.')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Primary (active) Azure region. Each allowed region has a short code in regionCodes.')
@allowed([
  'westus3'
  'eastus'
])
param primaryLocation string = 'westus3'

@description('Secondary (warm standby) Azure region, the platform pair of the primary.')
@allowed([
  'westus3'
  'eastus'
])
param secondaryLocation string = 'eastus'

@description('Deploy the secondary region stamp. Prod enables it; dev runs primary-only to halve cost.')
param deploySecondaryRegion bool = false

@description('Address plan for the primary region.')
param primaryAddressPlan regionAddressPlan

@description('Address plan for the secondary region. Required when deploySecondaryRegion is true.')
param secondaryAddressPlan regionAddressPlan?

@description('Approved outbound HTTPS destinations for both regions. Empty keeps application traffic denied.')
param allowedOutboundFqdns array = []

@description('Extra CIDR ranges allowed to reach private endpoints over HTTPS in every region.')
param additionalPrivateEndpointSourceCidrs array = []

@description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
param managementSourceCidrs array = []

@description('Relative path probed by App Service health check in every region.')
param healthCheckPath string = '/'

@description('Deploy the optional management VM in the primary region.')
param enableVirtualMachine bool = false

@description('Management VM operating system.')
@allowed([
  'Linux'
  'Windows'
])
param virtualMachineOsType string = 'Linux'

@description('Management VM local administrator username.')
@minLength(1)
@maxLength(64)
param virtualMachineAdminUsername string = 'azureadmin'

@description('SSH public key for Linux management VMs.')
param virtualMachineAdminSshPublicKey string = ''

@description('Local administrator password for Windows management VMs.')
@secure()
param virtualMachineAdminPassword string = ''

var isProd = environmentName == 'prod'
var regionCodes = {
  westus3: 'wus3'
  eastus: 'eus'
}
var primaryRegionCode = regionCodes[toLower(primaryLocation)]
var secondaryRegionCode = regionCodes[toLower(secondaryLocation)]
var globalResourceGroupName = 'rg-defenstack-${environmentName}-global'
var primaryResourceGroupName = 'rg-defenstack-${environmentName}-${primaryRegionCode}'
var secondaryResourceGroupName = 'rg-defenstack-${environmentName}-${secondaryRegionCode}'
var privateDnsZoneNames privateDnsZoneSet = {
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  sites: 'privatelink.azurewebsites.net'
  vault: 'privatelink.vaultcore.azure.net'
}

// Shared layer: Log Analytics and private DNS zones. Resource groups are pre-created (runbook 01).
module global 'modules/global.bicep' = {
  name: 'global-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    location: primaryLocation
    workspaceName: 'log-defenstack-${environmentName}'
    privateDnsZoneNames: privateDnsZoneNames
    workspaceReplicationLocation: isProd && deploySecondaryRegion ? secondaryLocation : ''
    enableDeleteLock: isProd
  }
}

module primaryStamp 'modules/regionStamp.bicep' = {
  name: 'region-${primaryRegionCode}'
  scope: resourceGroup(primaryResourceGroupName)
  params: {
    environmentName: environmentName
    regionRole: 'primary'
    location: primaryLocation
    regionCode: primaryRegionCode
    addressPlan: primaryAddressPlan
    logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
    privateDnsZoneIds: global.outputs.privateDnsZoneIds
    allowedOutboundFqdns: allowedOutboundFqdns
    additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
    managementSourceCidrs: managementSourceCidrs
    healthCheckPath: healthCheckPath
    enableVirtualMachine: enableVirtualMachine
    virtualMachineOsType: virtualMachineOsType
    virtualMachineAdminUsername: virtualMachineAdminUsername
    virtualMachineAdminSshPublicKey: virtualMachineAdminSshPublicKey
    virtualMachineAdminPassword: virtualMachineAdminPassword
  }
}

module secondaryStamp 'modules/regionStamp.bicep' = if (deploySecondaryRegion) {
  name: 'region-${secondaryRegionCode}'
  scope: resourceGroup(secondaryResourceGroupName)
  params: {
    environmentName: environmentName
    regionRole: 'secondary'
    location: secondaryLocation
    regionCode: secondaryRegionCode
    addressPlan: secondaryAddressPlan!
    logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
    privateDnsZoneIds: global.outputs.privateDnsZoneIds
    allowedOutboundFqdns: allowedOutboundFqdns
    additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
    managementSourceCidrs: managementSourceCidrs
    healthCheckPath: healthCheckPath
  }
}

var primaryVirtualNetworks = [
  {
    name: primaryStamp.outputs.hubVnetName
    id: primaryStamp.outputs.hubVnetId
  }
  {
    name: primaryStamp.outputs.spokeVnetName
    id: primaryStamp.outputs.spokeVnetId
  }
]
var secondaryVirtualNetworks = deploySecondaryRegion
  ? [
      {
        name: secondaryStamp!.outputs.hubVnetName
        id: secondaryStamp!.outputs.hubVnetId
      }
      {
        name: secondaryStamp!.outputs.spokeVnetName
        id: secondaryStamp!.outputs.spokeVnetId
      }
    ]
  : []

// Link every region's hub (firewall DNS proxy) and spoke to each shared zone.
module privateDnsLinks 'modules/privateDnsZoneLinks.bicep' = [for zone in items(privateDnsZoneNames): {
  name: 'dns-links-${zone.key}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    zoneName: zone.value
    virtualNetworks: concat(primaryVirtualNetworks, secondaryVirtualNetworks)
  }
}]

output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
