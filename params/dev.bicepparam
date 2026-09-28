using '../main.bicep'

// Non-secret dev parameters: primary region only (rg-defenstack-dev-global, rg-defenstack-dev-wus3).
// Secret values go in a git-ignored *.local.bicepparam overlay, never here.
param environmentName = 'dev'
param deploySecondaryRegion = false
param primaryAddressPlan = {
  hubAddressSpace: [
    '10.21.0.0/16'
  ]
  firewallSubnetPrefix: '10.21.0.0/26'
  spokeAddressSpace: [
    '10.20.0.0/16'
  ]
  privateEndpointSubnetPrefix: '10.20.1.0/24'
  appServiceIntegrationSubnetPrefix: '10.20.2.0/24'
  managementSubnetPrefix: '10.20.3.0/24'
}
param allowedOutboundFqdns = []
