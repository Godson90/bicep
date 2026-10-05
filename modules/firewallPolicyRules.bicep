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

@description('This region\'s part in cross-region Azure Monitor traffic over the hub peering (prod with DR): Host owns the AMPLS private endpoint, Client forwards its spoke to it, None deploys no cross-region rules.')
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

// Entra ID sign-in host for this cloud, for example login.microsoftonline.com.
var entraLoginHost = split(environment().authentication.loginEndpoint, '/')[2]

// Host: an application rule, so the firewall SNATs the other region's traffic to its own address and the private
// endpoint's replies return through it (a network rule would keep the remote source, which the spoke cannot route).
var monitorHostCollection = {
  name: 'peer-spoke-to-azure-monitor'
  priority: 250
  ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
  action: {
    type: 'Allow'
  }
  rules: [
    {
      ruleType: 'ApplicationRule'
      name: 'azure-monitor-private-link'
      sourceAddresses: monitorClientPrefixes
      protocols: [
        {
          protocolType: 'Https'
          port: 443
        }
      ]
      targetFqdns: [
        '*.applicationinsights.azure.com'
        '*.monitor.azure.com'
        '*.ods.opinsights.azure.com'
        '*.oms.opinsights.azure.com'
        '*.agentsvc.azure-automation.net'
      ]
    }
  ]
}

// Client: a network rule that forwards, unchanged, only to the Host region's private-endpoint subnet; the AzureFirewallSubnet
// route table sends it to the Host firewall over the peering.
var monitorClientCollection = {
  name: 'spoke-to-peer-azure-monitor'
  priority: 250
  ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
  action: {
    type: 'Allow'
  }
  rules: [
    {
      ruleType: 'NetworkRule'
      name: 'azure-monitor-private-endpoint'
      ipProtocols: [
        'TCP'
      ]
      sourceAddresses: monitorClientPrefixes
      destinationAddresses: monitorPrivateEndpointPrefixes
      destinationPorts: [
        '443'
      ]
    }
  ]
}

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
      {
        // Endpoints the AADSSHLoginForLinux / AADLoginForWindows extensions call to sign admins in with Entra ID.
        name: 'entra-login'
        priority: 160
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'entra-sign-in'
            sourceAddresses: managementAddressPrefixes
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              entraLoginHost
              'device.${entraLoginHost}'
              'enterpriseregistration.windows.net'
              'pas.windows.net'
              'packages.microsoft.com'
            ]
          }
        ]
      }
      {
        // Defender for Servers Plan 2 deploys Defender for Endpoint, which reports through its streamlined endpoint (Phase 7).
        name: 'defender-for-endpoint'
        priority: 170
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'defender-for-endpoint'
            sourceAddresses: managementAddressPrefixes
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.endpoint.security.microsoft.com'
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

// Prod with DR: the other region's spoke reaches the single AMPLS private endpoint through both firewalls. Broader
// cross-region traffic waits for Phase 8.
resource crossRegionMonitoring 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = if (monitorPeeringRole != 'None') {
  parent: firewallPolicy
  name: 'cross-region-monitoring'
  properties: {
    priority: 250
    ruleCollections: monitorPeeringRole == 'Host' ? [
      monitorHostCollection
    ] : [
      monitorClientCollection
    ]
  }
  // approved-https-egress is optional, so wait for platform-egress too and never run beside another group.
  dependsOn: [
    platformEgress
    approvedHttpsEgress
  ]
}
