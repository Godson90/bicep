// One Azure Monitor Private Link Scope (AMPLS) for the whole platform. The shared private DNS zones are linked to
// every VNet, so a second scope or endpoint would overwrite the first one's records (one AMPLS per DNS).

@description('Azure Monitor Private Link Scope name.')
@minLength(1)
@maxLength(255)
param scopeName string

@description('Resource IDs of the Azure Monitor resources reachable through the scope: the Log Analytics workspace and every Application Insights component.')
param scopedResourceIds array

// PrivateOnly: networks connected to the scope reach only the scoped resources, for both ingestion and query.
resource privateLinkScope 'Microsoft.Insights/privateLinkScopes@2021-09-01' = {
  name: scopeName
  location: 'global'
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
  }
}

resource scopedResources 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = [for linkedResourceId in scopedResourceIds: {
  parent: privateLinkScope
  name: last(split(linkedResourceId, '/'))
  properties: {
    linkedResourceId: linkedResourceId
  }
}]

output id string = privateLinkScope.id
output name string = privateLinkScope.name
