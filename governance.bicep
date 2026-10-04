// Subscription governance and posture (Phase 7): Microsoft Defender for Cloud plans, the security contact and Azure
// Policy with its exemptions. An operator deploys it with az deployment sub create (runbook 07). main.bicep and the
// pipeline never do, so the pipeline identity needs no rights over Defender for Cloud or Azure Policy (ADR-026).
targetScope = 'subscription'

import { environmentAdminGroups, environmentRegionLayout } from 'modules/types.bicep'

@description('Addresses that receive Defender for Cloud alert emails. The parameter file reads them from the SECURITY_CONTACT_EMAILS environment variable.')
@minLength(1)
param securityContactEmails string[]

@description('Monthly cap, in GB per storage account, on Defender for Storage on-upload malware scanning. -1 removes the cap.')
@minValue(-1)
param malwareScanCapGbPerMonth int = 5000

@description('Enforcement of every deny assignment. DoNotEnforce (audit-first) reports compliance without blocking; switch to Default once compliance is clean (ADR-027, runbook 07).')
@allowed([
  'DoNotEnforce'
  'Default'
])
param denyEnforcement string = 'DoNotEnforce'

@description('Environments deployed in this subscription. Their public IPs are allowed and their flow-log accounts exempted; every listed stamp must already exist (runbook 07).')
@minLength(1)
param environments ('dev' | 'prod')[] = [
  'dev'
  'prod'
]

@description('Regions each environment runs in, mirroring the dev and prod parameter files: dev primary-only, prod with the East US warm standby.')
param environmentRegions environmentRegionLayout = {
  dev: [
    'westus3'
  ]
  prod: [
    'westus3'
    'eastus'
  ]
}

@description('The Entra ID admin group of each environment (runbook 03), granted the DefenStack JIT Requester role at its primary regional resource group, where the jump host runs. Empty skips that environment.')
param adminGroupObjectIds environmentAdminGroups = {
  dev: ''
  prod: ''
}

@description('Legacy resource group that gets a dated waiver from the deny assignments until runbook 01a tears it down. Empty skips the waiver.')
param legacyResourceGroupName string = 'defenStack'

@description('Date the legacy waiver expires, as yyyy-MM-dd (end of that day, UTC).')
@minLength(10)
@maxLength(10)
param legacyWaiverExpiresOn string

// The same region codes as main.bicep; a test pins the parity.
var regionCodes = {
  westus3: 'wus3'
  eastus: 'eus'
}
var platformLocations = [
  'westus3'
  'eastus'
]

// Every region stamp in this subscription, named as main.bicep names them. The first region is the primary.
var stamps = flatten(map(environments, environmentName => map(environmentRegions[environmentName], (location, index) => {
  environmentName: environmentName
  location: location
  isPrimary: index == 0
  regionCode: regionCodes[location]
  resourceGroupName: 'rg-defenstack-${environmentName}-${regionCodes[location]}'
})))

// Every public IP a region stamp may create, named as regionStamp.bicep names them; vpnGateway.bicep appends -1
// and -2 for the active-active gateway. Includes the admin-access IPs a warm standby creates only during failover.
func publicIpNames(environmentName string, regionCode string) string[] => [
  'pip-afw-defenstack-${environmentName}-${regionCode}'
  'pip-bas-defenstack-${environmentName}-${regionCode}'
  'pip-vpng-defenstack-${environmentName}-${regionCode}-1'
  'pip-vpng-defenstack-${environmentName}-${regionCode}-2'
]

// The jump host runs in the primary stamp only (regionStamp.bicep), so the JIT Requester role is assigned there.
var jumpHostStamps = filter(stamps, stamp => stamp.isPrimary && !empty(adminGroupObjectIds[stamp.environmentName]))

var allowedPublicIpNames = flatten(map(stamps, stamp => publicIpNames(stamp.environmentName, stamp.regionCode)))

// The resource types whose modules send both logs and metrics to the workspace. Storage logs live on the blob
// service; public IPs, VNets and the jump host send no logs, so they are not audited.
var diagnosticResourceTypes = [
  'Microsoft.Network/azureFirewalls'
  'Microsoft.Network/bastionHosts'
  'Microsoft.Network/virtualNetworkGateways'
  'Microsoft.Cdn/profiles'
  'Microsoft.KeyVault/vaults'
  'Microsoft.Web/sites'
  'Microsoft.Storage/storageAccounts/blobServices'
]

module defenderPlans 'modules/governance/defenderPlans.bicep' = {
  name: 'governance-defender-plans'
  params: {
    malwareScanCapGbPerMonth: malwareScanCapGbPerMonth
  }
}

module securityContacts 'modules/governance/securityContacts.bicep' = {
  name: 'governance-security-contacts'
  params: {
    emails: securityContactEmails
  }
}

module policies 'modules/governance/policies.bicep' = {
  name: 'governance-policies'
  params: {
    denyEnforcement: denyEnforcement
    allowedLocations: concat(platformLocations, [
      'global'
    ])
    allowedResourceGroupLocations: platformLocations
    allowedPublicIpNames: allowedPublicIpNames
    diagnosticResourceTypes: diagnosticResourceTypes
  }
}

// Each flow-log account keeps public network access behind a deny-all firewall (ADR-023), so it is exempted.
module flowLogExemptions 'modules/governance/flowLogStorageExemption.bicep' = [for stamp in stamps: {
  name: 'governance-flow-log-exemption-${stamp.environmentName}-${stamp.regionCode}'
  scope: resourceGroup(stamp.resourceGroupName)
  params: {
    environmentName: stamp.environmentName
    location: stamp.location
    regionCode: stamp.regionCode
    policyAssignmentId: policies.outputs.storagePublicNetworkAssignmentId
  }
}]

module legacyWaiver 'modules/governance/legacyWaiver.bicep' = if (!empty(legacyResourceGroupName)) {
  name: 'governance-legacy-waiver'
  scope: resourceGroup(legacyResourceGroupName)
  params: {
    policyAssignmentIds: policies.outputs.denyAssignmentIds
    expiresOn: legacyWaiverExpiresOn
  }
}

module jitRequesterRole 'modules/governance/jitRequesterRole.bicep' = {
  name: 'governance-jit-requester-role'
}

// Requesting JIT access is separate from signing in: the admin group also holds Virtual Machine Administrator Login.
module jitRequesterAssignments 'modules/governance/jitRequesterAssignment.bicep' = [for stamp in jumpHostStamps: {
  name: 'governance-jit-requester-${stamp.environmentName}-${stamp.regionCode}'
  scope: resourceGroup(stamp.resourceGroupName)
  params: {
    principalId: adminGroupObjectIds[stamp.environmentName]
    roleDefinitionId: jitRequesterRole.outputs.roleDefinitionId
  }
}]

output defenderPlanNames string[] = defenderPlans.outputs.planNames
output allowedPublicIpNames string[] = allowedPublicIpNames
output jitRequesterRoleDefinitionId string = jitRequesterRole.outputs.roleDefinitionId
