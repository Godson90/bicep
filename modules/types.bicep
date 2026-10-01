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
@description('Private DNS zone names (or resource IDs) keyed by private endpoint group.')
type privateDnsZoneSet = {
  @description('Blob storage zone.')
  blob: string

  @description('App Service (sites) zone.')
  sites: string

  @description('Key Vault zone.')
  vault: string
}

@export()
@description('A virtual network to link to a private DNS zone.')
type virtualNetworkReference = {
  @description('VNet name; used to build a unique link name.')
  name: string

  @description('VNet resource ID.')
  id: string
}
