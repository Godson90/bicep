@description('Azure region for Bastion.')
param location string

@description('Bastion host name.')
@minLength(1)
@maxLength(80)
param bastionName string

@description('Bastion public IP name.')
@minLength(1)
@maxLength(80)
param publicIpName string

@description('AzureBastionSubnet resource ID.')
param subnetId string

@description('Availability zones for Bastion and its public IP, for example [\'1\', \'2\', \'3\']. Zones are fixed at creation.')
param availabilityZones array = []

@description('Log Analytics workspace resource ID for Bastion audit logs.')
param logAnalyticsWorkspaceId string

// Static Standard public IP; Bastion is the only inbound internet entry point for admin sessions.
resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
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

// Standard SKU: native client (az network bastion ssh/rdp) and IP-based connect need it.
resource bastion 'Microsoft.Network/bastionHosts@2024-07-01' = {
  name: bastionName
  location: location
  zones: empty(availabilityZones) ? null : availabilityZones
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableIpConnect: true
    scaleUnits: 2
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

// Session audit trail (who connected to which VM, when) in the central workspace.
resource bastionDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: bastion
  name: 'bastion-diagnostics'
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

output id string = bastion.id
output name string = bastion.name
