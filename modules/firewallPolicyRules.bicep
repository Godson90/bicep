// Baseline rule collection groups shared by every regional firewall policy (ADR-010).
// Rule collection groups on one policy must not update concurrently, so each group depends on the previous one.

@description('Existing firewall policy name in this resource group.')
param firewallPolicyName string

@description('Spoke CIDR ranges permitted to use the firewall DNS proxy, Azure Monitor egress, and approved application rules.')
param spokeAddressPrefixes array

@description('Management subnet CIDR ranges permitted to reach OS update endpoints (Windows Update, Ubuntu archives).')
param managementAddressPrefixes array

@description('Point-to-site VPN client pools permitted to open SSH/RDP sessions to the management subnet.')
param vpnClientAddressPrefixes array

@description('Approved outbound FQDNs for application traffic. An empty list deploys no application allowlist.')
param allowedOutboundFqdns array = []


resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' existing = {
  name: firewallPolicyName
}

// Platform egress for the spoke VNet: DNS proxy and Azure Monitor Agent ingestion.
resource dnsEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
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
            // With the firewall's DNS proxy on (dnsSettings.enableProxy in
            // azureFirewall.bicep), spoke clients query the firewall's own
            // private IP for DNS, which the firewall's DNS proxy itself
            // resolves and never appears as network traffic evaluated by this
            // rule collection group. This rule instead covers a spoke client
            // that bypasses the proxy and queries 168.63.129.16 (Azure's
            // recursive resolver) directly — a supported but non-default
            // configuration. Under the normal, proxied path this rule is
            // inert (nothing matches it); it exists as a fallback, not the
            // primary DNS path.
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
      {
        name: 'azure-monitor'
        priority: 110
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'azure-monitor-agent'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: spokeAddressPrefixes
            destinationAddresses: [
              'AzureMonitor'
              'AzureResourceManager'
            ]
            destinationPorts: [
              '443'
            ]
          }
        ]
      }
    ]
  }
}

// Admin sessions from VPN clients to the management subnet. GatewaySubnet routes spoke traffic here, so
// the firewall logs every SSH/RDP session. Private endpoint traffic is direct and NSG-enforced (ADR-013).
resource adminAccess 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
  parent: firewallPolicy
  name: 'admin-access'
  properties: {
    priority: 120
    ruleCollections: [
      {
        name: 'vpn-to-management'
        priority: 120
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'vpn-ssh-rdp'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: vpnClientAddressPrefixes
            destinationAddresses: managementAddressPrefixes
            destinationPorts: [
              '22'
              '3389'
            ]
          }
        ]
      }
    ]
  }
  dependsOn: [
    dnsEgress
  ]
}

// OS update endpoints for management VMs only; the App Service subnet never gets these.
resource platformEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
  parent: firewallPolicy
  name: 'platform-egress'
  properties: {
    priority: 150
    ruleCollections: [
      {
        name: 'os-updates'
        priority: 150
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'windows-update'
            sourceAddresses: managementAddressPrefixes
            protocols: [
              {
                protocolType: 'Http'
                port: 80
              }
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            fqdnTags: [
              'WindowsUpdate'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'ubuntu-archives'
            sourceAddresses: managementAddressPrefixes
            protocols: [
              {
                protocolType: 'Http'
                port: 80
              }
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              'archive.ubuntu.com'
              'security.ubuntu.com'
              'azure.archive.ubuntu.com'
              '*.azure.archive.ubuntu.com'
            ]
          }
        ]
      }
    ]
  }
  dependsOn: [
    adminAccess
  ]
}

// Optional application allowlist; no group is deployed when the allowlist is empty.
resource approvedHttpsEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = if (!empty(allowedOutboundFqdns)) {
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
  dependsOn: [
    platformEgress
  ]
}
