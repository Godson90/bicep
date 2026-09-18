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

@description('Approved outbound FQDNs for App Service traffic. An empty list denies application traffic by default.')
param allowedOutboundFqdns array = []

// Static Standard public IP used by Azure Firewall for controlled egress.
resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Central policy containing DNS and explicitly approved outbound rules.
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' = {
  name: firewallPolicyName
  location: location
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
    dnsSettings: {
      enableProxy: true
    }
  }
}

// DNS proxy access for the spoke VNet.
resource firewallDnsRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
  parent: firewallPolicy
  name: 'dns-egress'
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'dns'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'azure-dns'
            ipProtocols: [
              'UDP'
              'TCP'
            ]
            sourceAddresses: spokeAddressPrefixes
            destinationAddresses: [
              '168.63.129.16'
            ]
            destinationPorts: [
              '53'
            ]
          }
        ]
      }
    ]
  }
}

// Optional allowlist; no application rule group is deployed when the allowlist is empty.
resource firewallApplicationRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = if (!empty(allowedOutboundFqdns)) {
  parent: firewallPolicy
  name: 'approved-https-egress'
  properties: {
    priority: 200
    ruleCollections: [
      {
        name: 'approved-https'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'approved-fqdns'
            sourceAddresses: spokeAddressPrefixes
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: allowedOutboundFqdns
          }
        ]
      }
    ]
  }
}

// Standard Azure Firewall attached only to the dedicated hub subnet.
resource firewall 'Microsoft.Network/azureFirewalls@2025-01-01' = {
  name: firewallName
  location: location
  properties: {
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
}

// Firewall activity and metrics sent to the central workspace.
resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: firewall
  name: 'firewall-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
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

output id string = firewall.id
output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpId string = firewallPublicIp.id
output policyId string = firewallPolicy.id
