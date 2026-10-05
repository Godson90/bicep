// Azure Policy for the whole subscription (Phase 7): the Microsoft cloud security benchmark in audit, deny
// assignments that go live audit-first through denyEnforcement (ADR-027), the custom public IP allowlist and the
// diagnostic settings audit. No assignment has a managed identity, and nothing is remediated.
targetScope = 'subscription'

@description('Enforcement of every deny assignment: DoNotEnforce reports compliance without blocking; Default blocks (ADR-027).')
@allowed([
  'DoNotEnforce'
  'Default'
])
param denyEnforcement string

@description('Locations where resources may be created, including global.')
@minLength(1)
param allowedLocations string[]

@description('Locations where resource groups may be created.')
@minLength(1)
param allowedResourceGroupLocations string[]

@description('Every public IP name the platform may create: the firewall, Bastion and VPN gateway IPs of each stamp.')
@minLength(1)
param allowedPublicIpNames string[]

@description('Resource types audited for a diagnostic setting.')
@minLength(1)
param diagnosticResourceTypes string[]

// Built-in "should disable public network access" policies. Storage stays first: the flow-log exemption uses it.
var publicNetworkAccessPolicies = [
  {
    name: 'defenstack-deny-storage-public-network'
    displayName: 'Storage accounts should disable public network access'
    definitionId: 'b2982f36-99f2-4db5-8eff-283140c09693'
  }
  {
    name: 'defenstack-deny-key-vault-public-network'
    displayName: 'Azure Key Vault should disable public network access'
    definitionId: '405c5871-3e91-4644-8a63-58e19d68ff5b'
  }
  {
    name: 'defenstack-deny-app-public-network'
    displayName: 'App Service apps should disable public network access'
    definitionId: '1b5ef780-c53c-4a64-87f3-bb9c8c8094ba'
  }
  {
    name: 'defenstack-deny-app-slot-public-network'
    displayName: 'App Service app slots should disable public network access'
    definitionId: '701a595d-38fb-4a66-ae6d-fb3735217622'
  }
  {
    name: 'defenstack-deny-function-public-network'
    displayName: 'Function apps should disable public network access'
    definitionId: '969ac98b-88a8-449f-883c-2e9adb123127'
  }
  {
    name: 'defenstack-deny-function-slot-public-network'
    displayName: 'Function app slots should disable public network access'
    definitionId: '11c82d0c-db9f-4d7b-97c5-f3f9aa957da2'
  }
]

// Azure Policy shows who owns each assignment; changes go through this file, never the portal.
var assignmentMetadata = {
  assignedBy: 'DefenStack governance.bicep (runbook 07)'
}

// The benchmark's policies only audit by default, so the initiative is enforced from the start.
resource cloudSecurityBenchmark 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
  name: 'defenstack-mcsb'
  properties: {
    metadata: assignmentMetadata
    displayName: 'Microsoft cloud security benchmark'
    description: 'Security posture baseline, audit only (Phase 7, runbook 07).'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')
    enforcementMode: 'Default'
  }
}

// The effect is Deny from the start; denyEnforcement carries the audit phase (ADR-027).
resource publicNetworkAccess 'Microsoft.Authorization/policyAssignments@2025-11-01' = [for policy in publicNetworkAccessPolicies: {
  name: policy.name
  properties: {
    metadata: assignmentMetadata
    displayName: policy.displayName
    description: 'Data services are reached through private endpoints only (Phase 7, ADR-027).'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policy.definitionId)
    enforcementMode: denyEnforcement
    parameters: {
      effect: {
        value: 'Deny'
      }
    }
    nonComplianceMessages: [
      {
        message: 'Public network access must be disabled; use the private endpoint. Exemptions: runbook 07.'
      }
    ]
  }
}]

// Neither location policy has an effect parameter: both always deny.
resource allowedLocationsAssignment 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
  name: 'defenstack-allowed-locations'
  properties: {
    metadata: assignmentMetadata
    displayName: 'Allowed locations'
    description: 'Resources only in the platform regions, or global (Phase 7, ADR-027).'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
    enforcementMode: denyEnforcement
    parameters: {
      listOfAllowedLocations: {
        value: allowedLocations
      }
    }
    nonComplianceMessages: [
      {
        message: 'Only the platform regions (and global) are allowed. Exemptions: runbook 07.'
      }
    ]
  }
}

resource allowedResourceGroupLocationsAssignment 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
  name: 'defenstack-allowed-resource-group-locations'
  properties: {
    metadata: assignmentMetadata
    displayName: 'Allowed locations for resource groups'
    description: 'Resource groups only in the platform regions (Phase 7, ADR-027).'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e765b5de-1225-4ba3-bd56-1ac6695af988')
    enforcementMode: denyEnforcement
    parameters: {
      listOfAllowedLocations: {
        value: allowedResourceGroupLocations
      }
    }
    nonComplianceMessages: [
      {
        message: 'Resource groups are allowed only in the platform regions. Exemptions: runbook 07.'
      }
    ]
  }
}

// No built-in policy allows public IPs by name. Azure Policy compares the names case-insensitively.
resource publicIpDefinition 'Microsoft.Authorization/policyDefinitions@2025-11-01' = {
  name: 'defenstack-deny-public-ip-except-allowlist'
  properties: {
    policyType: 'Custom'
    mode: 'Indexed'
    displayName: 'Deny public IP addresses except the platform allowlist'
    description: 'Only the firewall, Bastion and VPN gateway public IPs named by the platform may exist (Phase 7, ADR-027).'
    metadata: {
      category: 'Network'
    }
    parameters: {
      allowedNames: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed public IP names'
          description: 'Names of the public IPs the platform deploys.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Network/publicIPAddresses'
          }
          {
            field: 'name'
            // Evaluated by Azure Policy, not by the deployment (Bicep escapes the leading bracket).
            notIn: '[parameters(\'allowedNames\')]'
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

resource publicIpAssignment 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
  name: 'defenstack-deny-public-ip'
  properties: {
    metadata: assignmentMetadata
    displayName: 'Deny public IP addresses except the platform allowlist'
    description: 'Public IPs only for the firewall, Bastion and VPN gateways (Phase 7, ADR-027).'
    policyDefinitionId: publicIpDefinition.id
    enforcementMode: denyEnforcement
    parameters: {
      allowedNames: {
        value: allowedPublicIpNames
      }
    }
    nonComplianceMessages: [
      {
        message: 'This public IP name is not on the platform allowlist (governance.bicep). Exemptions: runbook 07.'
      }
    ]
  }
}

// AuditIfNotExists only: no identity, no remediation.
resource diagnosticSettingsAudit 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
  name: 'defenstack-audit-diagnostic-settings'
  properties: {
    metadata: assignmentMetadata
    displayName: 'Audit diagnostic setting for selected resource types'
    description: 'Platform resource types that send logs and metrics to the workspace keep doing so (Phase 7).'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '7f89b1eb-583c-429a-8828-af049802c1d9')
    enforcementMode: 'Default'
    parameters: {
      listOfResourceTypes: {
        value: diagnosticResourceTypes
      }
    }
  }
}

output storagePublicNetworkAssignmentId string = publicNetworkAccess[0].id

// Built from the names so the list is known up front; consumers still wait for this module to finish.
output denyAssignmentIds string[] = concat(
  map(publicNetworkAccessPolicies, policy => subscriptionResourceId('Microsoft.Authorization/policyAssignments', policy.name)),
  [
    allowedLocationsAssignment.id
    allowedResourceGroupLocationsAssignment.id
    publicIpAssignment.id
  ]
)
