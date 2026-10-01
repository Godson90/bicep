import { regionAddressPlan, privateDnsZoneSet } from 'types.bicep'

@description('Deployment environment.')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Role of this region in the active/passive design. Only the primary gets zone-redundant App Service capacity and the optional management VM.')
@allowed([
  'primary'
  'secondary'
])
param regionRole string

@description('Azure region for this stamp.')
param location string

@description('Short lowercase region code used in resource names, for example wus3 or eus.')
@minLength(2)
@maxLength(4)
param regionCode string

@description('Hub and spoke address plan for this region.')
param addressPlan regionAddressPlan

@description('Central Log Analytics workspace resource ID from the global layer.')
param logAnalyticsWorkspaceId string

@description('Shared private DNS zone resource IDs from the global layer.')
param privateDnsZoneIds privateDnsZoneSet

@description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
param allowedOutboundFqdns array = []

@description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
param additionalPrivateEndpointSourceCidrs array = []

@description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
param managementSourceCidrs array = []

@description('Relative path probed by App Service health check.')
param healthCheckPath string = '/'

@description('Deploy the optional management VM (primary region only).')
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

@description('Deploy Azure Bastion and the point-to-site VPN gateway in this region. The warm standby leaves it off until failover.')
param deployAdminAccess bool = false

@description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
param adminGroupObjectId string = ''

var isProd = environmentName == 'prod'
var isPrimary = regionRole == 'primary'
var nameSuffix = uniqueString(subscription().id, environmentName, location)
var availabilityZones = [
  '1'
  '2'
  '3'
]
var names = {
  hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
  spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
  firewall: 'afw-defenstack-${environmentName}-${regionCode}'
  firewallPolicy: 'afwp-defenstack-${environmentName}-${regionCode}'
  firewallPublicIp: 'pip-afw-defenstack-${environmentName}-${regionCode}'
  storageAccount: 'st${regionCode}${nameSuffix}'
  keyVault: 'kv-${regionCode}-${nameSuffix}'
  appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
  appService: 'app-defenstack-${environmentName}-${regionCode}-${take(nameSuffix, 6)}'
  virtualMachine: 'vm${regionCode}${take(nameSuffix, 7)}'
  bastion: 'bas-defenstack-${environmentName}-${regionCode}'
  bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
  vpnGateway: 'vpng-defenstack-${environmentName}-${regionCode}'
  vpnGatewayPublicIp: 'pip-vpng-defenstack-${environmentName}-${regionCode}'
}
// Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
// the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
// Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
var adminSourceCidrs = concat([
  addressPlan.bastionSubnetPrefix
  addressPlan.vpnClientAddressPool
], managementSourceCidrs)
var privateEndpointSubnetName = 'private-endpoints'
var appServiceIntegrationSubnetName = 'appservice-integration'

module storage 'storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: names.storageAccount
    storageAccountSkuName: isProd ? 'Standard_GRS' : 'Standard_LRS'
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

module keyVault 'keyVault.bicep' = {
  name: 'key-vault'
  params: {
    location: location
    keyVaultName: names.keyVault
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    enablePurgeProtection: true
    enabledForTemplateDeployment: true
    enableDeleteLock: isProd
  }
}

module hubNetwork 'hubNetwork.bicep' = {
  name: 'hub-network'
  params: {
    location: location
    vnetName: names.hubVnet
    addressSpace: addressPlan.hubAddressSpace
    firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
    bastionSubnetAddressPrefix: addressPlan.bastionSubnetPrefix
    gatewaySubnetAddressPrefix: addressPlan.gatewaySubnetPrefix
    firewallPrivateIp: firewallPrivateIp
    spokeAddressPrefixes: addressPlan.spokeAddressSpace
    bastionTargetAddressPrefixes: [
      addressPlan.managementSubnetPrefix
    ]
    enableDeleteLock: isProd
  }
}

module azureFirewall 'azureFirewall.bicep' = {
  name: 'azure-firewall'
  params: {
    location: location
    firewallName: names.firewall
    firewallPolicyName: names.firewallPolicy
    publicIpName: names.firewallPublicIp
    firewallSubnetId: hubNetwork.outputs.firewallSubnetId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    spokeAddressPrefixes: addressPlan.spokeAddressSpace
    managementAddressPrefixes: [
      addressPlan.managementSubnetPrefix
    ]
    vpnClientAddressPrefixes: [
      addressPlan.vpnClientAddressPool
    ]
    allowedOutboundFqdns: allowedOutboundFqdns
    threatIntelMode: isProd ? 'Deny' : 'Alert'
    availabilityZones: availabilityZones
    firewallTier: 'Premium'
    idpsMode: isProd ? 'Deny' : 'Alert'
    enableDeleteLock: isProd
  }
}

module spokeNetwork 'spokeNetwork.bicep' = {
  name: 'spoke-network'
  params: {
    location: location
    vnetName: names.spokeVnet
    firewallPrivateIp: azureFirewall.outputs.privateIp
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    vnetAddressSpace: addressPlan.spokeAddressSpace
    privateEndpointSubnetAddressPrefix: addressPlan.privateEndpointSubnetPrefix
    appServiceIntegrationSubnetAddressPrefix: addressPlan.appServiceIntegrationSubnetPrefix
    virtualMachineSubnetAddressPrefix: addressPlan.managementSubnetPrefix
    approvedPrivateEndpointSourceCidrs: concat([
      addressPlan.appServiceIntegrationSubnetPrefix
      addressPlan.managementSubnetPrefix
      addressPlan.vpnClientAddressPool
    ], additionalPrivateEndpointSourceCidrs)
    privateEndpointSubnetName: privateEndpointSubnetName
    appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
    enableDeleteLock: isProd
    managementSourceCidrs: adminSourceCidrs
  }
}

module appService 'appService.bicep' = {
  name: 'app-service'
  params: {
    location: location
    appServiceAppName: names.appService
    appServicePlanName: names.appServicePlan
    environmentType: environmentName
    vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    healthCheckPath: healthCheckPath
    zoneRedundant: isProd && isPrimary
    instanceCount: isProd && isPrimary ? 3 : 1
  }
}

module virtualMachine 'virtualMachine.bicep' = if (enableVirtualMachine && isPrimary) {
  name: 'virtual-machine'
  params: {
    location: location
    vmName: names.virtualMachine
    osType: virtualMachineOsType
    subnetId: spokeNetwork.outputs.virtualMachineSubnetId
    adminUsername: virtualMachineAdminUsername
    adminSshPublicKey: virtualMachineAdminSshPublicKey
    adminPassword: virtualMachineAdminPassword
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    managementSourceCidrs: adminSourceCidrs
    adminGroupObjectId: adminGroupObjectId
  }
}

module bastion 'bastion.bicep' = if (deployAdminAccess) {
  name: 'bastion'
  params: {
    location: location
    bastionName: names.bastion
    publicIpName: names.bastionPublicIp
    subnetId: hubNetwork.outputs.bastionSubnetId
    availabilityZones: availabilityZones
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
  // The hub resolves DNS through the firewall, so admin access waits for it.
  dependsOn: [
    azureFirewall
  ]
}

module vpnGateway 'vpnGateway.bicep' = if (deployAdminAccess) {
  name: 'vpn-gateway'
  params: {
    location: location
    gatewayName: names.vpnGateway
    publicIpNamePrefix: names.vpnGatewayPublicIp
    gatewaySubnetId: hubNetwork.outputs.gatewaySubnetId
    skuName: isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'
    availabilityZones: availabilityZones
    vpnClientAddressPool: addressPlan.vpnClientAddressPool
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
  dependsOn: [
    azureFirewall
  ]
}

module networkIntegration 'networkIntegration.bicep' = {
  name: 'network-integration'
  params: {
    hubVnetName: names.hubVnet
    hubVnetId: hubNetwork.outputs.id
    spokeVnetName: names.spokeVnet
    spokeVnetId: spokeNetwork.outputs.id
    storageAccountName: names.storageAccount
    storageAccountId: storage.outputs.id
    storageContainerName: storage.outputs.blobContainerName
    appServicePrincipalId: appService.outputs.appServicePrincipalId
    appServiceName: names.appService
    useHubGateway: deployAdminAccess
  }
  // Gateway transit on the peering needs a provisioned gateway.
  dependsOn: [
    vpnGateway
  ]
}

module privateConnectivity 'privateConnectivity.bicep' = {
  name: 'private-connectivity'
  params: {
    location: location
    storageAccountId: storage.outputs.id
    storageAccountName: names.storageAccount
    appServiceId: appService.outputs.appServiceAppId
    appServiceName: names.appService
    privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
    keyVaultId: keyVault.outputs.id
    keyVaultName: names.keyVault
    privateDnsZoneIds: privateDnsZoneIds
  }
}

output hubVnetName string = names.hubVnet
output hubVnetId string = hubNetwork.outputs.id
output spokeVnetName string = names.spokeVnet
output spokeVnetId string = spokeNetwork.outputs.id
output firewallPrivateIp string = azureFirewall.outputs.privateIp
output expectedFirewallPrivateIp string = firewallPrivateIp
output bastionName string = deployAdminAccess ? names.bastion : ''
output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
output appServiceName string = names.appService
output appServiceHostName string = appService.outputs.appServiceAppHostName
output keyVaultName string = names.keyVault
output storageAccountName string = names.storageAccount
