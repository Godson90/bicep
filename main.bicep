@description('Azure region for all regional resources.')
param location string = 'WestUS3'

@description('Globally unique storage account name.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'dfsk${uniqueString(resourceGroup().id)}'

@description('Globally unique App Service application name.')
@minLength(2)
@maxLength(60)
param appServiceAppName string = 'defenstack-mvp${uniqueString(resourceGroup().id)}'

@description('Log Analytics workspace name.')
@minLength(4)
@maxLength(63)
param logAnalyticsWorkspaceName string = 'defenstack-law-${uniqueString(resourceGroup().id)}'

@description('Globally unique Key Vault name. Use only letters, numbers, and hyphens.')
@minLength(3)
@maxLength(24)
param keyVaultName string = 'kv${uniqueString(resourceGroup().id)}'

@description('Dedicated hub VNet name.')
@minLength(2)
@maxLength(64)
param hubVnetName string = 'defenstack-hub-${uniqueString(resourceGroup().id)}'

@description('Non-overlapping address space for the firewall hub VNet.')
param hubVnetAddressSpace array = [
  '10.1.0.0/16'
]

@description('Azure Firewall name.')
@minLength(1)
@maxLength(56)
param firewallName string = 'defenstack-firewall-${uniqueString(resourceGroup().id)}'

@description('Azure Firewall Policy name.')
@minLength(1)
@maxLength(80)
param firewallPolicyName string = 'defenstack-fw-policy-${uniqueString(resourceGroup().id)}'

@description('Azure Firewall public IP name.')
@minLength(1)
@maxLength(80)
param firewallPublicIpName string = 'defenstack-fw-pip-${uniqueString(resourceGroup().id)}'

@description('Deploy the optional private VM workload.')
param enableVirtualMachine bool = false

@description('Virtual machine name. It must also be valid as the computer hostname.')
@minLength(1)
@maxLength(15)
param virtualMachineName string = 'vm${uniqueString(resourceGroup().id)}'

@description('Virtual machine operating system.')
@allowed([
  'Linux'
  'Windows'
])
param virtualMachineOsType string = 'Linux'

@description('Virtual machine local administrator username.')
@minLength(1)
@maxLength(64)
param virtualMachineAdminUsername string = 'azureadmin'

@description('SSH public key for Linux VM deployments.')
param virtualMachineAdminSshPublicKey string = ''

@description('Local administrator password for Windows VM deployments.')
@secure()
param virtualMachineAdminPassword string = ''

@description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
param allowedOutboundFqdns array = []

@description('CIDR ranges allowed to reach private endpoints over HTTPS.')
param approvedPrivateEndpointSourceCidrs array = [
  '10.0.2.0/24'
]

@description('CIDR prefix for AzureFirewallSubnet. It must be at least /26 and contained in hubVnetAddressSpace.')
param firewallSubnetAddressPrefix string = '10.1.0.0/26'

@description('Deployment environment that controls redundancy, plan sizing, and deletion protection.')
@allowed([
  'prod'
  'dev'
  'test'
])
param environmentType string

var storageAccountSkuName = (environmentType == 'prod') ? 'Standard_GRS' : 'Standard_LRS'
var spokeVnetName = uniqueString(resourceGroup().id)
var privateEndpointSubnetName = 'private-endpoints'
var appServiceIntegrationSubnetName = 'appservice-integration'

@description('Central diagnostics workspace module.')
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    workspaceName: logAnalyticsWorkspaceName
  }
}

@description('Private storage account and storage diagnostics module.')
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: storageAccountName
    storageAccountSkuName: storageAccountSkuName
    logAnalyticsWorkspaceId: monitoring.outputs.id
  }
}

@description('RBAC-enabled private Key Vault with soft delete, purge protection, and diagnostics.')
module keyVault 'modules/keyVault.bicep' = {
  name: 'key-vault'
  params: {
    location: location
    keyVaultName: keyVaultName
    logAnalyticsWorkspaceId: monitoring.outputs.id
    enablePurgeProtection: true
  }
}

@description('Dedicated hub VNet and Azure Firewall subnet module.')
module hubNetwork 'modules/hubNetwork.bicep' = {
  name: 'hub-network'
  params: {
    location: location
    vnetName: hubVnetName
    addressSpace: hubVnetAddressSpace
    firewallSubnetAddressPrefix: firewallSubnetAddressPrefix
  }
}

@description('Azure Firewall, policy, public IP, DNS proxy, and diagnostics module.')
module azureFirewall 'modules/azureFirewall.bicep' = {
  name: 'azure-firewall'
  params: {
    location: location
    firewallName: firewallName
    firewallPolicyName: firewallPolicyName
    publicIpName: firewallPublicIpName
    firewallSubnetId: hubNetwork.outputs.firewallSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.id
    spokeAddressPrefixes: [
      '10.0.0.0/16'
    ]
    allowedOutboundFqdns: allowedOutboundFqdns
  }
}

@description('Spoke VNet, subnet NSGs, App Service route table, and subnet associations module.')
module spokeNetwork 'modules/spokeNetwork.bicep' = {
  name: 'spoke-network'
  params: {
    location: location
    vnetName: spokeVnetName
    firewallPrivateIp: azureFirewall.outputs.privateIp
    logAnalyticsWorkspaceId: monitoring.outputs.id
    approvedPrivateEndpointSourceCidrs: approvedPrivateEndpointSourceCidrs
    privateEndpointSubnetName: privateEndpointSubnetName
    appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
    enableDeleteLock: environmentType == 'prod'
  }
}

@description('App Service plan, site, managed identity, route-all, and diagnostics module.')
module appService 'modules/appService.bicep' = {
  name: 'app-service'
  params: {
    location: location
    appServiceAppName: appServiceAppName
    environmentType: environmentType
    vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.id
  }
}

@description('Linux or Windows VM module with private networking, managed identity, and trusted launch security.')
module virtualMachine 'modules/virtualMachine.bicep' = if (enableVirtualMachine) {
  name: 'virtual-machine'
  params: {
    location: location
    vmName: virtualMachineName
    osType: virtualMachineOsType
    subnetId: spokeNetwork.outputs.virtualMachineSubnetId
    adminUsername: virtualMachineAdminUsername
    adminSshPublicKey: virtualMachineAdminSshPublicKey
    adminPassword: virtualMachineAdminPassword
    logAnalyticsWorkspaceId: monitoring.outputs.id
  }
}

@description('Reciprocal hub/spoke peerings and managed identity storage RBAC module.')
module networkIntegration 'modules/networkIntegration.bicep' = {
  name: 'network-integration'
  params: {
    hubVnetName: hubVnetName
    hubVnetId: hubNetwork.outputs.id
    spokeVnetName: spokeVnetName
    spokeVnetId: spokeNetwork.outputs.id
    storageAccountName: storageAccountName
    storageAccountId: storage.outputs.id
    appServicePrincipalId: appService.outputs.appServicePrincipalId
    appServiceName: appServiceAppName
  }
}

@description('Private DNS zones, VNet links, private endpoints, and DNS zone groups module.')
module privateConnectivity 'modules/privateConnectivity.bicep' = {
  name: 'private-connectivity'
  params: {
    location: location
    storageAccountId: storage.outputs.id
    storageAccountName: storageAccountName
    appServiceId: appService.outputs.appServiceAppId
    appServiceName: appServiceAppName
    spokeVnetId: spokeNetwork.outputs.id
    hubVnetId: hubNetwork.outputs.id
    privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
    keyVaultId: keyVault.outputs.id
    keyVaultName: keyVaultName
  }
}

output appServiceAppHostName string = appService.outputs.appServiceAppHostName
