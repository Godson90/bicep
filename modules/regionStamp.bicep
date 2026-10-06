import { regionAddressPlan, privateDnsZoneSet, hubPeeringPlan, alertThresholdSet } from 'types.bicep'

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

@description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
param primaryStorageAccountId string = ''

@description('Warm standby only: name of the primary region storage account.')
param primaryStorageAccountName string = ''

@description('Application secrets written to this region\'s Key Vault, as { name: value } (ADR-019).')
@secure()
param keyVaultSecrets object = {}

@description('Prod with DR only: routing and Azure Monitor rules for the hub-to-hub peering with the other region. Absent in dev and in prod without DR.')
param hubPeering hubPeeringPlan?

@description('Resource ID of the environment\'s action group, which every regional alert notifies (Phase 6).')
param actionGroupId string

@description('Thresholds for the count-based regional alerts (Phase 6).')
param alertThresholds alertThresholdSet

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
  appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
  flowLogStorageAccount: 'stfl${regionCode}${nameSuffix}'
  flowLogIdentity: 'id-flowlogs-defenstack-${environmentName}-${regionCode}'
  recoveryServicesVault: 'rsv-defenstack-${environmentName}-${regionCode}'
}
// Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
// the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
// Admin sessions arrive from the Bastion subnet, the VPN pool and any ADR-approved management sources
// (managementSourceCidrs). The management subnet NSG allows these sources, and the jump host's JIT policy opens its NIC
// NSG to them on request (ADR-028).
var adminSourceCidrs = concat([
  addressPlan.bastionSubnetPrefix
  addressPlan.vpnClientAddressPool
], managementSourceCidrs)
var monitorPeeringRole = hubPeering.?monitorRole ?? 'None'
// The region hosting the AMPLS endpoint SNATs the other region's monitoring traffic at its firewall, so the
// private-endpoint NSG must admit the firewall subnet there, to the AMPLS endpoint's application security group only (Phase 6).
var peerTrafficSourceCidrs = monitorPeeringRole == 'Host' ? [
  addressPlan.firewallSubnetPrefix
] : []
var privateEndpointSubnetName = 'private-endpoints'
var appServiceIntegrationSubnetName = 'appservice-integration'

module storage 'storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: names.storageAccount
    // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
    storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
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
    secrets: keyVaultSecrets
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
    remoteSpokeAddressPrefixes: hubPeering.?remoteSpokeAddressPrefixes ?? []
    remoteFirewallPrivateIp: hubPeering.?remoteFirewallPrivateIp ?? ''
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
    monitorPeeringRole: monitorPeeringRole
    monitorClientPrefixes: hubPeering.?monitorClientPrefixes ?? []
    monitorPrivateEndpointPrefixes: hubPeering.?monitorPrivateEndpointPrefixes ?? []
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
    monitorPeerSourceCidrs: peerTrafficSourceCidrs
    privateEndpointSubnetName: privateEndpointSubnetName
    appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
    enableDeleteLock: isProd
    managementSourceCidrs: adminSourceCidrs
  }
}

// One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
module appInsights 'appInsights.bicep' = {
  name: 'app-insights'
  params: {
    location: location
    componentName: names.appInsights
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
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
    applicationInsightsConnectionString: appInsights.outputs.connectionString
  }
}

module appInsightsPublisher 'appInsightsPublisher.bicep' = {
  name: 'app-insights-publisher'
  params: {
    componentName: appInsights.outputs.name
    publisherPrincipalId: appService.outputs.appServicePrincipalId
    publisherAppServiceName: names.appService
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

// One Recovery Services vault per stamp (Phase 8): geo-redundant with cross-region restore, and the jump host's daily
// backup where the jump host exists. Protection waits for the VM through its ID.
module recoveryServicesVault 'recoveryServicesVault.bicep' = {
  name: 'recovery-services-vault'
  params: {
    location: location
    vaultName: names.recoveryServicesVault
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    virtualMachineId: enableVirtualMachine && isPrimary ? virtualMachine!.outputs.id : ''
    enableDeleteLock: isProd
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

// The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
  name: 'storage-secondary-endpoint'
  params: {
    location: location
    primaryStorageAccountId: primaryStorageAccountId
    primaryStorageAccountName: primaryStorageAccountName
    privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
    blobPrivateDnsZoneId: privateDnsZoneIds.blob
  }
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

// VNet flow logs with Traffic Analytics (Phase 6): a regional keyless account and the identity that writes to it.
module flowLogStorage 'flowLogStorage.bicep' = {
  name: 'flow-log-storage'
  params: {
    location: location
    storageAccountName: names.flowLogStorageAccount
    // Zone-redundant in prod; flow logs are regional telemetry, so no geo copy. Dev: LRS (ADR-008).
    storageAccountSkuName: isProd ? 'Standard_ZRS' : 'Standard_LRS'
    identityName: names.flowLogIdentity
  }
}

// Network Watcher lives in NetworkWatcherRG (one per region per subscription), so the flow logs are deployed there.
module flowLogs 'flowLogs.bicep' = {
  name: 'flow-logs-${environmentName}-${regionCode}'
  scope: resourceGroup('NetworkWatcherRG')
  params: {
    location: location
    virtualNetworks: [
      {
        name: names.hubVnet
        id: hubNetwork.outputs.id
      }
      {
        name: names.spokeVnet
        id: spokeNetwork.outputs.id
      }
    ]
    storageAccountId: flowLogStorage.outputs.id
    identityId: flowLogStorage.outputs.identityId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

// Regional platform alerts (Phase 6), all to the environment's action group. Triage steps: runbook 06.
module metricAlerts 'metricAlerts.bicep' = {
  name: 'metric-alerts'
  params: {
    namePrefix: 'alert-defenstack-${environmentName}-${regionCode}'
    actionGroupId: actionGroupId
    rules: [
      {
        name: 'firewall-health'
        description: 'Azure Firewall health is below 90 percent.'
        severity: 1
        resourceId: azureFirewall.outputs.id
        metricNamespace: 'Microsoft.Network/azureFirewalls'
        metricName: 'FirewallHealth'
        operator: 'LessThan'
        threshold: '90'
        timeAggregation: 'Average'
      }
      {
        name: 'firewall-snat-ports'
        description: 'Azure Firewall SNAT port utilisation is above 80 percent.'
        severity: 2
        resourceId: azureFirewall.outputs.id
        metricNamespace: 'Microsoft.Network/azureFirewalls'
        metricName: 'SNATPortUtilization'
        operator: 'GreaterThan'
        threshold: '80'
        timeAggregation: 'Maximum'
      }
      {
        name: 'app-http-5xx'
        description: 'The App Service returned more HTTP 5xx responses than the threshold in 15 minutes.'
        severity: 2
        resourceId: appService.outputs.appServiceAppId
        metricNamespace: 'Microsoft.Web/sites'
        metricName: 'Http5xx'
        operator: 'GreaterThan'
        threshold: string(alertThresholds.appServiceHttp5xx)
        timeAggregation: 'Total'
      }
      {
        name: 'app-health-check'
        description: 'Some App Service instances are failing the health check.'
        severity: 1
        resourceId: appService.outputs.appServiceAppId
        metricNamespace: 'Microsoft.Web/sites'
        metricName: 'HealthCheckStatus'
        operator: 'LessThan'
        threshold: '100'
        timeAggregation: 'Average'
      }
      {
        name: 'key-vault-availability'
        description: 'Key Vault availability is below 99.9 percent.'
        severity: 2
        resourceId: keyVault.outputs.id
        metricNamespace: 'Microsoft.KeyVault/vaults'
        metricName: 'Availability'
        operator: 'LessThan'
        threshold: '99.9'
        timeAggregation: 'Average'
      }
      {
        name: 'key-vault-forbidden'
        description: 'Key Vault refused more requests with 403 Forbidden than the threshold in 15 minutes.'
        severity: 3
        resourceId: keyVault.outputs.id
        metricNamespace: 'Microsoft.KeyVault/vaults'
        metricName: 'ServiceApiResult'
        operator: 'GreaterThan'
        threshold: string(alertThresholds.keyVaultForbidden)
        timeAggregation: 'Count'
        dimensions: [
          {
            name: 'StatusCode'
            operator: 'Include'
            values: [
              '403'
            ]
          }
        ]
      }
      {
        name: 'vpn-p2s-connections'
        description: 'More point-to-site VPN connections than expected.'
        severity: 3
        resourceId: deployAdminAccess ? vpnGateway!.outputs.id : ''
        metricNamespace: 'Microsoft.Network/virtualNetworkGateways'
        metricName: 'P2SConnectionCount'
        operator: 'GreaterThan'
        threshold: string(alertThresholds.vpnP2sConnections)
        timeAggregation: 'Maximum'
        // Only where this region has the gateway (deployAdminAccess).
        deploy: deployAdminAccess
      }
    ]
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
output appServiceId string = appService.outputs.appServiceAppId
output appServiceHostName string = appService.outputs.appServiceAppHostName
output keyVaultName string = names.keyVault
output storageAccountName string = names.storageAccount
output storageAccountId string = storage.outputs.id
output storageContainerName string = storage.outputs.blobContainerName
output appServicePrincipalId string = appService.outputs.appServicePrincipalId
output appInsightsName string = appInsights.outputs.name
output appInsightsId string = appInsights.outputs.id
output privateEndpointSubnetId string = spokeNetwork.outputs.privateEndpointSubnetId
output monitorAsgId string = spokeNetwork.outputs.amplsAsgId
output recoveryServicesVaultId string = recoveryServicesVault.outputs.id
output recoveryServicesVaultName string = names.recoveryServicesVault
output dataCollectionEndpointId string = enableVirtualMachine && isPrimary ? virtualMachine!.outputs.dataCollectionEndpointId : ''
