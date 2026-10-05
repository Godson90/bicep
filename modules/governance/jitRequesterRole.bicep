// The DefenStack JIT Requester custom role (Phase 7, ADR-028): just enough to see the jump host's just-in-time policy
// and request access through it. It grants no sign-in; Virtual Machine Administrator Login still does that (runbook 03).
targetScope = 'subscription'

// Least-privilege actions for requesting JIT access, as Microsoft documents them; runbook 07 lists them as a live check.
var roleActions = [
  'Microsoft.Security/locations/jitNetworkAccessPolicies/read'
  'Microsoft.Security/locations/jitNetworkAccessPolicies/initiate/action'
  'Microsoft.Security/locations/jitNetworkAccessPolicies/*/read'
  'Microsoft.Compute/virtualMachines/read'
  'Microsoft.Network/networkInterfaces/read'
  'Microsoft.Network/networkInterfaces/*/read'
  'Microsoft.Network/publicIPAddresses/read'
]

// The name is a GUID derived from the subscription, so every redeploy updates the same definition.
resource jitRequester 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'DefenStack JIT Requester')
  properties: {
    roleName: 'DefenStack JIT Requester'
    description: 'Request just-in-time SSH/RDP access to DefenStack jump hosts (ADR-028, runbook 07). Assigned to each environment admin group at its primary regional resource group.'
    type: 'CustomRole'
    permissions: [
      {
        actions: roleActions
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      subscription().id
    ]
  }
}

output roleDefinitionId string = jitRequester.id
