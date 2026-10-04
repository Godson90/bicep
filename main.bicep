targetScope = 'subscription'

import { regionAddressPlan, privateDnsZoneSet, alertThresholdSet } from 'modules/types.bicep'

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

@description('Extra CIDR ranges allowed to administer management VMs over SSH/RDP, beyond the AzureBastionSubnet and VPN client pool of each region.')
param managementSourceCidrs array = []

@description('Deploy Azure Bastion and the point-to-site VPN gateway in the primary region.')
param deployPrimaryAdminAccess bool = true

@description('Deploy Azure Bastion and the point-to-site VPN gateway in the secondary region. Off in steady state; turned on during failover.')
param deploySecondaryAdminAccess bool = false

@description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
param adminGroupObjectId string = ''

@description('Custom domain served by Front Door, for example app.example.com, hosted at an external DNS provider. Empty serves only the azurefd.net hostname.')
param customDomainHostName string = ''

@description('Application secrets written to every regional Key Vault, as { name: value }. The pipeline supplies them from the KEYVAULT_SECRETS_JSON environment secret; never put values in a committed parameter file (ADR-019).')
@secure()
param keyVaultSecrets object = {}

@description('Relative path probed by App Service health check in every region.')
param healthCheckPath string = '/'

@description('Email address that receives every platform alert. The pipeline passes the GitHub environment variable ALERT_EMAIL and refuses an empty value for prod; empty creates the action group with no receiver.')
param alertEmail string = ''

@description('Thresholds for the count-based alerts: App Service 5xx, Key Vault 403s, VPN connections and WAF blocks.')
param alertThresholds alertThresholdSet = {
  appServiceHttp5xx: 10
  keyVaultForbidden: 10
  vpnP2sConnections: 20
  frontDoorWafBlocks: 100
}

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
// Region names as Azure Service Health reports them, for the Service Health alert.
var regionDisplayNames = {
  westus3: 'West US 3'
  eastus: 'East US'
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
  // Azure Monitor Private Link Scope zones (Phase 6); the AMPLS endpoint also registers in the blob zone above.
  monitor: 'privatelink.monitor.azure.com'
  oms: 'privatelink.oms.opinsights.azure.com'
  ods: 'privatelink.ods.opinsights.azure.com'
  agentsvc: 'privatelink.agentsvc.azure-automation.net'
}

// Prod with DR (Phase 6): the East US App Service and management subnets may reach the one AMPLS endpoint, in the
// primary private-endpoint subnet, through both firewalls and the hub-to-hub peering. Nothing else crosses yet (Phase 8).
var monitorClientPrefixes = deploySecondaryRegion ? [
  secondaryAddressPlan!.appServiceIntegrationSubnetPrefix
  secondaryAddressPlan!.managementSubnetPrefix
] : []
var monitorPrivateEndpointPrefixes = [
  primaryAddressPlan.privateEndpointSubnetPrefix
]

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

// The subscription Activity Log goes to the shared workspace, where Sentinel reads it as Azure Activity (Phase 6).
module activityLog 'modules/activityLog.bicep' = {
  name: 'activity-log-${environmentName}'
  params: {
    settingName: 'activity-log-defenstack-${environmentName}'
    logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
  }
}

// One action group per environment for every platform alert (Phase 6).
module actionGroup 'modules/actionGroup.bicep' = {
  name: 'action-group-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    actionGroupName: 'ag-defenstack-${environmentName}'
    shortName: 'ds-${environmentName}-ops'
    alertEmail: alertEmail
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
    deployAdminAccess: deployPrimaryAdminAccess
    adminGroupObjectId: adminGroupObjectId
    keyVaultSecrets: keyVaultSecrets
    actionGroupId: actionGroup.outputs.id
    alertThresholds: alertThresholds
    // A firewall always takes the first usable address (.4) of its AzureFirewallSubnet (see regionStamp.bicep).
    hubPeering: deploySecondaryRegion ? {
      remoteFirewallPrivateIp: cidrHost(secondaryAddressPlan!.firewallSubnetPrefix, 3)
      remoteSpokeAddressPrefixes: secondaryAddressPlan!.spokeAddressSpace
      monitorRole: 'Host'
      monitorClientPrefixes: monitorClientPrefixes
      monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
    } : null
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
    deployAdminAccess: deploySecondaryAdminAccess
    primaryStorageAccountId: isProd ? primaryStamp.outputs.storageAccountId : ''
    primaryStorageAccountName: isProd ? primaryStamp.outputs.storageAccountName : ''
    keyVaultSecrets: keyVaultSecrets
    actionGroupId: actionGroup.outputs.id
    alertThresholds: alertThresholds
    hubPeering: {
      remoteFirewallPrivateIp: cidrHost(primaryAddressPlan.firewallSubnetPrefix, 3)
      remoteSpokeAddressPrefixes: primaryAddressPlan.spokeAddressSpace
      monitorRole: 'Client'
      monitorClientPrefixes: monitorClientPrefixes
      monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
    }
  }
}

// Hub-to-hub global peering, both ways, once both hubs exist (brought forward from Phase 8). The sides are created
// one after the other, since each peering operation updates both VNets.
module primaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
  name: 'hub-peering-${primaryRegionCode}-to-${secondaryRegionCode}'
  scope: resourceGroup(primaryResourceGroupName)
  params: {
    localVnetName: primaryStamp.outputs.hubVnetName
    remoteVnetId: secondaryStamp!.outputs.hubVnetId
    peeringName: 'hub-to-${secondaryRegionCode}-hub'
  }
}

module secondaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
  name: 'hub-peering-${secondaryRegionCode}-to-${primaryRegionCode}'
  scope: resourceGroup(secondaryResourceGroupName)
  params: {
    localVnetName: secondaryStamp!.outputs.hubVnetName
    remoteVnetId: primaryStamp.outputs.hubVnetId
    peeringName: 'hub-to-${primaryRegionCode}-hub'
  }
  dependsOn: [
    primaryHubPeering
  ]
}

// The warm-standby App Service may read (never write) the primary application container (ADR-020).
module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion && isProd) {
  name: 'storage-reader-${secondaryRegionCode}'
  scope: resourceGroup(primaryResourceGroupName)
  params: {
    storageAccountName: primaryStamp.outputs.storageAccountName
    storageContainerName: primaryStamp.outputs.storageContainerName
    readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
    readerAppServiceName: secondaryStamp!.outputs.appServiceName
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

// Origins in failover order: the primary region first (priority 1), then the warm standby (priority 2).
var primaryOrigin = {
  name: 'app-${primaryRegionCode}'
  appServiceId: primaryStamp.outputs.appServiceId
  hostName: primaryStamp.outputs.appServiceHostName
  location: primaryLocation
}
var secondaryOrigins = deploySecondaryRegion
  ? [
      {
        name: 'app-${secondaryRegionCode}'
        appServiceId: secondaryStamp!.outputs.appServiceId
        hostName: secondaryStamp!.outputs.appServiceHostName
        location: secondaryLocation
      }
    ]
  : []

// Public ingress: one Front Door per environment in the global resource group, after both stamps exist.
module frontDoor 'modules/frontDoor.bicep' = {
  name: 'front-door-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    profileName: 'afd-defenstack-${environmentName}'
    endpointName: 'fde-defenstack-${environmentName}'
    wafPolicyName: 'wafdefenstack${environmentName}'
    origins: concat([
      primaryOrigin
    ], secondaryOrigins)
    healthProbePath: healthCheckPath
    customDomainHostName: customDomainHostName
    logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
    enableDeleteLock: isProd
  }
}

// Global platform alerts (Phase 6): Front Door origin health and WAF blocks, and Service Health for the platform
// regions. The backup job alert waits for Phase 8.
module globalMetricAlerts 'modules/metricAlerts.bicep' = {
  name: 'global-metric-alerts-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    namePrefix: 'alert-defenstack-${environmentName}'
    actionGroupId: actionGroup.outputs.id
    rules: [
      {
        name: 'front-door-origin-health'
        description: 'Front Door sees less than 90 percent of origin health probes succeed.'
        severity: 1
        resourceId: frontDoor.outputs.id
        metricNamespace: 'Microsoft.Cdn/profiles'
        metricName: 'OriginHealthPercentage'
        operator: 'LessThan'
        threshold: '90'
        timeAggregation: 'Average'
      }
      {
        name: 'front-door-waf-blocks'
        description: 'The Front Door WAF blocked more requests than the threshold in 15 minutes.'
        severity: 2
        resourceId: frontDoor.outputs.id
        metricNamespace: 'Microsoft.Cdn/profiles'
        metricName: 'WebApplicationFirewallRequestCount'
        operator: 'GreaterThan'
        threshold: string(alertThresholds.frontDoorWafBlocks)
        timeAggregation: 'Total'
        dimensions: [
          {
            name: 'Action'
            operator: 'Include'
            values: [
              'Block'
            ]
          }
        ]
      }
    ]
  }
}

module serviceHealthAlert 'modules/serviceHealthAlert.bicep' = {
  name: 'service-health-alert-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    alertName: 'alert-defenstack-${environmentName}-service-health'
    regions: concat([
      regionDisplayNames[toLower(primaryLocation)]
    ], deploySecondaryRegion ? [
      regionDisplayNames[toLower(secondaryLocation)]
    ] : [], [
      'Global'
    ])
    actionGroupId: actionGroup.outputs.id
  }
}

// Link every region's hub (firewall DNS proxy) and spoke to each shared zone.
module privateDnsLinks 'modules/privateDnsZoneLinks.bicep' = [for zone in items(privateDnsZoneNames): {
  name: 'dns-links-${zone.key}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    zoneName: zone.value
    virtualNetworks: concat(primaryVirtualNetworks, secondaryVirtualNetworks)
  }
}]

// Private-only monitoring (Phase 6): one scope holds the workspace and every regional App Insights component.
module monitorPrivateLinkScope 'modules/monitorPrivateLinkScope.bicep' = {
  name: 'monitor-private-link-scope-${environmentName}'
  scope: resourceGroup(globalResourceGroupName)
  params: {
    scopeName: 'ampls-defenstack-${environmentName}'
    scopedResourceIds: concat([
      global.outputs.logAnalyticsWorkspaceId
      primaryStamp.outputs.appInsightsId
    ], deploySecondaryRegion ? [
      secondaryStamp!.outputs.appInsightsId
    ] : [])
  }
}

// The single azuremonitor endpoint, in the primary spoke, created once the scope holds every resource.
module monitorPrivateEndpoint 'modules/monitorPrivateEndpoint.bicep' = {
  name: 'monitor-private-endpoint-${environmentName}'
  scope: resourceGroup(primaryResourceGroupName)
  params: {
    location: primaryLocation
    privateLinkScopeId: monitorPrivateLinkScope.outputs.id
    privateLinkScopeName: monitorPrivateLinkScope.outputs.name
    privateEndpointSubnetId: primaryStamp.outputs.privateEndpointSubnetId
    privateDnsZoneIds: global.outputs.privateDnsZoneIds
  }
}

output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
output primaryResourceGroupName string = primaryResourceGroupName
output primaryBastionName string = primaryStamp.outputs.bastionName
output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
output frontDoorProfileName string = frontDoor.outputs.profileName
output globalResourceGroupName string = globalResourceGroupName
output appServiceIds array = concat([
  primaryStamp.outputs.appServiceId
], deploySecondaryRegion ? [
  secondaryStamp!.outputs.appServiceId
] : [])
output monitorPrivateLinkScopeName string = monitorPrivateLinkScope.outputs.name
