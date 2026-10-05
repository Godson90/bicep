@description('Azure region for the VPN gateway.')
param location string

@description('VPN gateway name.')
@minLength(1)
@maxLength(80)
param gatewayName string

@description('Name prefix for the two public IPs of the active-active gateway; -1 and -2 are appended.')
@minLength(1)
@maxLength(78)
param publicIpNamePrefix string

@description('GatewaySubnet resource ID.')
param gatewaySubnetId string

@description('Zone-redundant VPN gateway SKU.')
@allowed([
  'VpnGw1AZ'
  'VpnGw2AZ'
  'VpnGw3AZ'
])
param skuName string = 'VpnGw2AZ'

@description('Availability zones for the gateway public IP. AZ gateway SKUs spread across the zones of their public IP.')
param availabilityZones array = [
  '1'
  '2'
  '3'
]

@description('Point-to-site client address pool.')
param vpnClientAddressPool string

@description('Microsoft Entra tenant ID that authenticates VPN users.')
param tenantId string = tenant().tenantId

@description('Application (audience) ID of the Microsoft-registered Azure VPN Client app.')
param vpnClientAudience string = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'

@description('First customer-controlled gateway maintenance window, in UTC (yyyy-MM-dd HH:mm). It repeats every Sunday; Azure requires at least 5 hours.')
param maintenanceWindowStartDateTime string = '2026-10-04 06:00'

@description('Log Analytics workspace resource ID for gateway and P2S logs.')
param logAnalyticsWorkspaceId string

var instances = [
  1
  2
]

// One public IP per active-active instance.
resource gatewayPublicIps 'Microsoft.Network/publicIPAddresses@2025-01-01' = [for instance in instances: {
  name: '${publicIpNamePrefix}-${instance}'
  location: location
  zones: availabilityZones
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

// Point-to-site only: OpenVPN with Microsoft Entra ID authentication, no certificates or RADIUS.
resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-07-01' = {
  name: gatewayName
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation2'
    sku: {
      name: skuName
      tier: skuName
    }
    // Active-active: two instances, so planned maintenance or an instance failure drops only half the sessions.
    activeActive: true
    enableBgp: false
    ipConfigurations: [for (instance, i) in instances: {
      name: 'gateway-ipconfig-${instance}'
      properties: {
        privateIPAllocationMethod: 'Dynamic'
        subnet: {
          id: gatewaySubnetId
        }
        publicIPAddress: {
          id: gatewayPublicIps[i].id
        }
      }
    }]
    vpnClientConfiguration: {
      vpnClientAddressPool: {
        addressPrefixes: [
          vpnClientAddressPool
        ]
      }
      vpnClientProtocols: [
        'OpenVPN'
      ]
      vpnAuthenticationTypes: [
        'AAD'
      ]
      aadTenant: '${environment().authentication.loginEndpoint}${tenantId}/'
      aadAudience: vpnClientAudience
      // https://sts.windows.net/ is the public-cloud Entra issuer; sovereign clouds (e.g. Azure Government, Azure China) need their own issuer.
      aadIssuer: 'https://sts.windows.net/${tenantId}/'
    }
  }
}

resource gatewayDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vpnGateway
  name: 'vpn-gateway-diagnostics'
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

// Customer-controlled maintenance: Azure patches the gateway only inside this weekly window.
resource gatewayMaintenance 'Microsoft.Maintenance/maintenanceConfigurations@2023-04-01' = {
  name: '${gatewayName}-maintenance'
  location: location
  properties: {
    maintenanceScope: 'Resource'
    maintenanceWindow: {
      startDateTime: maintenanceWindowStartDateTime
      duration: '05:00'
      timeZone: 'UTC'
      recurEvery: 'Week Sunday'
    }
  }
}

resource gatewayMaintenanceAssignment 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = {
  name: '${gatewayName}-maintenance'
  scope: vpnGateway
  location: location
  properties: {
    maintenanceConfigurationId: gatewayMaintenance.id
    resourceId: vpnGateway.id
  }
}

output id string = vpnGateway.id
output name string = vpnGateway.name
