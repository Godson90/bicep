// Shared parameter contracts between the subscription entry point, the global layer, and region stamps.

@export()
@description('Address plan for one region: hub VNet with the firewall, Bastion and gateway subnets, spoke VNet with its three subnets, and the P2S VPN client pool.')
type regionAddressPlan = {
  @description('Hub VNet address space.')
  hubAddressSpace: string[]

  @description('AzureFirewallSubnet prefix (at least /26) inside hubAddressSpace.')
  firewallSubnetPrefix: string

  @description('AzureBastionSubnet prefix (at least /26) inside hubAddressSpace.')
  bastionSubnetPrefix: string

  @description('GatewaySubnet prefix (at least /27) inside hubAddressSpace.')
  gatewaySubnetPrefix: string

  @description('Point-to-site VPN client address pool. Must not overlap any VNet in any region or environment.')
  vpnClientAddressPool: string

  @description('Spoke VNet address space. Also the firewall source range for spoke egress rules.')
  spokeAddressSpace: string[]

  @description('private-endpoints subnet prefix inside spokeAddressSpace.')
  privateEndpointSubnetPrefix: string

  @description('appservice-integration subnet prefix inside spokeAddressSpace.')
  appServiceIntegrationSubnetPrefix: string

  @description('management subnet prefix inside spokeAddressSpace.')
  managementSubnetPrefix: string
}

@export()
@description('Private DNS zone names (or resource IDs) keyed by private endpoint group: the application zones plus the Azure Monitor Private Link Scope zones (Phase 6).')
type privateDnsZoneSet = {
  @description('Blob storage zone.')
  blob: string

  @description('App Service (sites) zone.')
  sites: string

  @description('Key Vault zone.')
  vault: string

  @description('Azure Monitor global endpoints zone (AMPLS).')
  monitor: string

  @description('Log Analytics workspace agent endpoints zone (AMPLS).')
  oms: string

  @description('Log Analytics workspace ingestion (ODS) endpoints zone (AMPLS).')
  ods: string

  @description('Log Analytics agent service endpoints zone (AMPLS).')
  agentsvc: string
}

@export()
@description('A virtual network to link to a private DNS zone.')
type virtualNetworkReference = {
  @description('VNet name; used to build a unique link name.')
  name: string

  @description('VNet resource ID.')
  id: string
}

@export()
@description('Prod with DR only: how this region\'s firewall carries traffic to and from the other region over the hub-to-hub global peering (Phase 6).')
type hubPeeringPlan = {
  @description('Private IP of the other region\'s firewall, the next hop for the other region\'s spoke.')
  remoteFirewallPrivateIp: string

  @description('Spoke address prefixes of the other region, routed from this AzureFirewallSubnet to the other firewall.')
  remoteSpokeAddressPrefixes: string[]

  @description('This region\'s part in Azure Monitor traffic: Host owns the AMPLS private endpoint, Client forwards its spoke to it.')
  monitorRole: 'Host' | 'Client'

  @description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
  monitorClientPrefixes: string[]

  @description('Private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint. Used by the Client rule.')
  monitorPrivateEndpointPrefixes: string[]
}

@export()
@description('A dimension filter on a metric alert, for example StatusCode = 403.')
type metricAlertDimension = {
  @description('Dimension name, for example StatusCode or Action.')
  name: string

  @description('Include matches only the values; Exclude matches everything else.')
  operator: 'Include' | 'Exclude'

  @description('Dimension values.')
  values: string[]
}

@export()
@description('One static-threshold metric alert on a single resource (Phase 6).')
type metricAlertRule = {
  @description('Short rule name, appended to the alert name prefix, for example firewall-health.')
  name: string

  @description('What the alert means. Shown in the alert email; runbook 06 has the triage steps.')
  description: string

  @description('Alert severity: 0 Critical, 1 Error, 2 Warning, 3 Informational, 4 Verbose.')
  severity: 0 | 1 | 2 | 3 | 4

  @description('Resource ID the metric is read from.')
  resourceId: string

  @description('Metric namespace, the resource type, for example Microsoft.Network/azureFirewalls.')
  metricNamespace: string

  @description('Exact metric name, for example FirewallHealth.')
  metricName: string

  @description('Comparison against the threshold.')
  operator: 'GreaterThan' | 'GreaterThanOrEqual' | 'LessThan' | 'LessThanOrEqual'

  @description('Threshold as text, for example \'90\' or \'99.9\'. Bicep has no decimal literals; the module converts it with json().')
  threshold: string

  @description('How the metric is aggregated over the window.')
  timeAggregation: 'Average' | 'Minimum' | 'Maximum' | 'Total' | 'Count'

  @description('Dimension filters. Omit for none.')
  dimensions: metricAlertDimension[]?

  @description('False skips the rule, for example the VPN alert in a region without a gateway. Defaults to true.')
  deploy: bool?
}

@export()
@description('Thresholds for the count-based platform alerts (Phase 6). Health and percentage alerts use fixed thresholds.')
type alertThresholdSet = {
  @description('App Service HTTP 5xx responses per region in a 15-minute window.')
  @minValue(1)
  appServiceHttp5xx: int

  @description('Key Vault requests refused with 403 per region in a 15-minute window.')
  @minValue(1)
  keyVaultForbidden: int

  @description('Point-to-site VPN connections on the gateway at any time in a 15-minute window.')
  @minValue(1)
  vpnP2sConnections: int

  @description('Front Door WAF blocked requests in a 15-minute window.')
  @minValue(1)
  frontDoorWafBlocks: int
}

@export()
@description('Regions each environment runs in, as main.bicep lays out its stamps: the primary first, then the warm standby (Phase 7 governance).')
type environmentRegionLayout = {
  @description('Dev regions. Dev runs primary-only (ADR-008).')
  dev: ('westus3' | 'eastus')[]

  @description('Prod regions: the primary, then the warm standby.')
  prod: ('westus3' | 'eastus')[]
}
