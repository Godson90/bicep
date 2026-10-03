@description('Azure region for the firewall resources.')
param location string

@description('Azure Firewall name.')
@minLength(1)
@maxLength(56)
param firewallName string

@description('Azure Firewall Policy name.')
@minLength(1)
@maxLength(80)
param firewallPolicyName string

@description('Azure Firewall public IP name.')
@minLength(1)
@maxLength(80)
param publicIpName string

@description('Azure Firewall subnet resource ID.')
param firewallSubnetId string

@description('Log Analytics workspace resource ID.')
param logAnalyticsWorkspaceId string

@description('Spoke CIDR ranges permitted to use the firewall DNS proxy and application rules.')
param spokeAddressPrefixes array

@description('Management subnet CIDR ranges permitted to reach OS update endpoints.')
param managementAddressPrefixes array

@description('Point-to-site VPN client pools permitted to reach the management subnet over SSH/RDP.')
param vpnClientAddressPrefixes array = []

@description('Approved outbound FQDNs for App Service traffic. An empty list denies application traffic by default.')
param allowedOutboundFqdns array = []

@description('Availability zones for the firewall and its public IP, for example [\'1\', \'2\', \'3\']. Zones are fixed at creation, so leave empty when updating an existing non-zonal firewall.')
param availabilityZones array = []

@description('Firewall and policy tier. Premium adds IDPS (and TLS inspection, deferred by ADR-011).')
@allowed([
  'Standard'
  'Premium'
])
param firewallTier string = 'Premium'

@description('Threat intelligence mode for the firewall policy.')
@allowed([
  'Alert'
  'Deny'
  'Off'
])
param threatIntelMode string = 'Deny'

@description('IDPS mode for Premium policies: Alert logs signature hits, Deny also blocks them. Ignored for Standard.')
@allowed([
  'Alert'
  'Deny'
  'Off'
])
param idpsMode string = 'Deny'

@description('Per-signature IDPS overrides for Premium policies, for example to Alert-only on one signature that false-positives against legitimate traffic. Find the signature ID in the AZFWIdpsSignature table\'s SignatureId column. Each entry: { id: \'<signatureId>\', mode: \'Alert\' | \'Deny\' | \'Off\' }. Empty by default; never used to disable IDPS as a whole (use idpsMode = \'Off\' for that, which this project does not do).')
param idpsSignatureOverrides array = []

@description('Apply CanNotDelete locks to the firewall, its policy, and its public IP.')
param enableDeleteLock bool = false

@description('This region\'s part in cross-region Azure Monitor traffic over the hub peering: Host, Client, or None (dev, or prod without DR).')
@allowed([
  'None'
  'Host'
  'Client'
])
param monitorPeeringRole string = 'None'

@description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
param monitorClientPrefixes array = []

@description('Client role: private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint.')
param monitorPrivateEndpointPrefixes array = []

var isPremium = firewallTier == 'Premium'

// Static Standard public IP used by Azure Firewall for controlled egress.
resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
  name: publicIpName
  location: location
  zones: empty(availabilityZones) ? null : availabilityZones
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Regional policy: threat intelligence, IDPS (Premium) and the DNS proxy. Rules come from firewallPolicyRules.bicep.
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' = {
  name: firewallPolicyName
  location: location
  properties: {
    sku: {
      tier: firewallTier
    }
    threatIntelMode: threatIntelMode
    intrusionDetection: isPremium ? {
      mode: idpsMode
      configuration: {
        signatureOverrides: idpsSignatureOverrides
      }
    } : null
    dnsSettings: {
      enableProxy: true
    }
  }
}

// Baseline rule collection groups shared by every regional policy (ADR-010).
module policyRules 'firewallPolicyRules.bicep' = {
  // One firewall per resource group, so a fixed deployment name is unique (policy names can exceed the 64-character limit).
  name: 'firewall-policy-rules'
  params: {
    firewallPolicyName: firewallPolicy.name
    spokeAddressPrefixes: spokeAddressPrefixes
    managementAddressPrefixes: managementAddressPrefixes
    vpnClientAddressPrefixes: vpnClientAddressPrefixes
    allowedOutboundFqdns: allowedOutboundFqdns
    monitorPeeringRole: monitorPeeringRole
    monitorClientPrefixes: monitorClientPrefixes
    monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
  }
}

// Firewall attached only to the dedicated hub subnet; applied after every rule collection group exists.
resource firewall 'Microsoft.Network/azureFirewalls@2025-01-01' = {
  name: firewallName
  location: location
  zones: empty(availabilityZones) ? null : availabilityZones
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: firewallTier
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'firewall-ipconfig'
        properties: {
          publicIPAddress: {
            id: firewallPublicIp.id
          }
          subnet: {
            id: firewallSubnetId
          }
        }
      }
    ]
  }
  dependsOn: [
    policyRules
  ]
}

// Firewall activity and metrics sent to the central workspace.
resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: firewall
  name: 'firewall-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource firewallLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: firewall
  name: '${firewallName}-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

resource firewallPolicyLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: firewallPolicy
  name: '${firewallPolicyName}-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

resource firewallPublicIpLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: firewallPublicIp
  name: '${publicIpName}-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

output id string = firewall.id
output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpId string = firewallPublicIp.id
output policyId string = firewallPolicy.id
