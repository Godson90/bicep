using '../main.bicep'

// Non-secret dev parameters: primary region only (rg-defenstack-dev-global, rg-defenstack-dev-wus3).
// Secret values go in a git-ignored *.local.bicepparam overlay, never here.
// VPN client pools: prod WUS3 172.16.200.0/24, prod EUS 172.16.201.0/24, dev 172.16.210.0/24 (never reuse across environments).
param environmentName = 'dev'
param deploySecondaryRegion = false
param primaryAddressPlan = {
  hubAddressSpace: [
    '10.21.0.0/16'
  ]
  firewallSubnetPrefix: '10.21.0.0/26'
  bastionSubnetPrefix: '10.21.0.64/26'
  gatewaySubnetPrefix: '10.21.0.128/27'
  vpnClientAddressPool: '172.16.210.0/24'
  spokeAddressSpace: [
    '10.20.0.0/16'
  ]
  privateEndpointSubnetPrefix: '10.20.1.0/24'
  appServiceIntegrationSubnetPrefix: '10.20.2.0/24'
  managementSubnetPrefix: '10.20.3.0/24'
}
param allowedOutboundFqdns = []
// Front Door custom domain at the external DNS host; empty until the domain exists (runbook 04).
param customDomainHostName = ''
