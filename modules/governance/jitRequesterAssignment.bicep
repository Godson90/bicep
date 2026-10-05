// Assigns the DefenStack JIT Requester role to one environment's admin group at a regional resource group that
// hosts a jump host (Phase 7, ADR-028). The resource group must already exist. PIM makes the group membership
// just-in-time, as for Virtual Machine Administrator Login (runbook 03).

@description('Object ID of the environment\'s Entra ID admin group.')
@minLength(36)
@maxLength(36)
param principalId string

@description('Resource ID of the DefenStack JIT Requester role definition.')
param roleDefinitionId string

// Deterministic name: the same resource group, group and role always give the same assignment.
resource jitRequester 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'Group'
    roleDefinitionId: roleDefinitionId
    description: 'Request just-in-time access to the jump host (ADR-028, runbook 07).'
  }
}

output roleAssignmentId string = jitRequester.id
