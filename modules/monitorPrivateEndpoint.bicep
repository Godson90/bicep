// The platform's single Azure Monitor private endpoint, in the primary spoke's private-endpoint subnet. Its NSG
// already admits HTTPS from the approved sources, and the shared zones make it resolvable from every linked VNet.
// The endpoint joins the spoke's AMPLS application security group, the only destination the NSG opens to the
// peer region's firewall-SNATed traffic (ADR-022). During a declared outage, failover.bicep adds a second endpoint
// in the East US spoke under its own name; its zone group re-points the shared records there (ADR-032).
import { privateDnsZoneSet } from 'types.bicep'

@description('Azure region for the private endpoint (the primary region).')
param location string

@description('Azure Monitor Private Link Scope resource ID.')
param privateLinkScopeId string

@description('Azure Monitor Private Link Scope name, used for deterministic private endpoint naming.')
@minLength(1)
@maxLength(255)
param privateLinkScopeName string

@description('Private endpoint name. The default keeps the Phase 6 primary endpoint name; failover.bicep names its East US endpoint.')
param privateEndpointName string = '${privateLinkScopeName}-pe'

@description('Private-endpoint subnet resource ID in the primary spoke.')
param privateEndpointSubnetId string

@description('Resource IDs of the shared private DNS zones created by the global layer.')
param privateDnsZoneIds privateDnsZoneSet

@description('Resource ID of the primary spoke\'s AMPLS application security group, which the endpoint joins.')
param applicationSecurityGroupId string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: privateEndpointName
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'azuremonitor'
        properties: {
          privateLinkServiceId: privateLinkScopeId
          groupIds: [
            'azuremonitor'
          ]
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
    applicationSecurityGroups: [
      {
        id: applicationSecurityGroupId
      }
    ]
  }
}

// Azure Monitor needs its four zones plus the shared blob zone (agent solution packs); the blob records are
// per storage account, so they sit beside the application's own blob records without conflict.
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'monitor'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.monitor
        }
      }
      {
        name: 'oms'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.oms
        }
      }
      {
        name: 'ods'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.ods
        }
      }
      {
        name: 'agentsvc'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.agentsvc
        }
      }
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.blob
        }
      }
    ]
  }
}

output id string = privateEndpoint.id
