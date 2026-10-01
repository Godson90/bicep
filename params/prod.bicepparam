using '../main.bicep'

// Non-secret prod parameters: West US 3 active, East US warm standby
// (rg-defenstack-prod-global, rg-defenstack-prod-wus3, rg-defenstack-prod-eus).
// Secret values go in a git-ignored *.local.bicepparam overlay, never here.
// VPN client pools: prod WUS3 172.16.200.0/24, prod EUS 172.16.201.0/24, dev 172.16.210.0/24 (never reuse across environments).
param environmentName = 'prod'
param deploySecondaryRegion = true
param primaryAddressPlan = {
  hubAddressSpace: [
    '10.1.0.0/16'
  ]
  firewallSubnetPrefix: '10.1.0.0/26'
  bastionSubnetPrefix: '10.1.0.64/26'
  gatewaySubnetPrefix: '10.1.0.128/27'
  vpnClientAddressPool: '172.16.200.0/24'
  spokeAddressSpace: [
    '10.0.0.0/16'
  ]
  privateEndpointSubnetPrefix: '10.0.1.0/24'
  appServiceIntegrationSubnetPrefix: '10.0.2.0/24'
  managementSubnetPrefix: '10.0.3.0/24'
}
param secondaryAddressPlan = {
  hubAddressSpace: [
    '10.11.0.0/16'
  ]
  firewallSubnetPrefix: '10.11.0.0/26'
  bastionSubnetPrefix: '10.11.0.64/26'
  gatewaySubnetPrefix: '10.11.0.128/27'
  vpnClientAddressPool: '172.16.201.0/24'
  spokeAddressSpace: [
    '10.10.0.0/16'
  ]
  privateEndpointSubnetPrefix: '10.10.1.0/24'
  appServiceIntegrationSubnetPrefix: '10.10.2.0/24'
  managementSubnetPrefix: '10.10.3.0/24'
}
param allowedOutboundFqdns = []
