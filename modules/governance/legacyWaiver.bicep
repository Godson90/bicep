// Waives the deny assignments on the legacy defenStack resource group until it is migrated and torn down
// (Phase 7, runbook 01a). Deployed into that resource group.

@description('Resource IDs of the deny assignments to waive.')
@minLength(1)
param policyAssignmentIds string[]

@description('Date the waivers expire, as yyyy-MM-dd (end of that day, UTC).')
@minLength(10)
@maxLength(10)
param expiresOn string

// Microsoft.Authorization/policyExemptions has no GA API version; 2026-01-01-preview is the latest (ADR-029).
resource waivers 'Microsoft.Authorization/policyExemptions@2026-01-01-preview' = [for assignmentId in policyAssignmentIds: {
  name: 'defenstack-legacy-waiver-${last(split(assignmentId, '/'))}'
  properties: {
    policyAssignmentId: assignmentId
    exemptionCategory: 'Waiver'
    expiresOn: '${expiresOn}T23:59:59Z'
    displayName: 'Legacy defenStack resource group, pending teardown'
    description: 'The pre-platform resource group is migrated and torn down by runbook 01a; until then the deny assignments do not apply to it.'
  }
}]
