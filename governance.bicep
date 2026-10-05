// Subscription governance and posture (Phase 7): Microsoft Defender for Cloud plans and the security contact.
// An operator deploys it with az deployment sub create (runbook 07). main.bicep and the pipeline never do, so the
// pipeline identity needs no rights over Defender for Cloud (ADR-026).
targetScope = 'subscription'

@description('Addresses that receive Defender for Cloud alert emails. The parameter file reads them from the SECURITY_CONTACT_EMAILS environment variable.')
@minLength(1)
param securityContactEmails string[]

@description('Monthly cap, in GB per storage account, on Defender for Storage on-upload malware scanning. -1 removes the cap.')
@minValue(-1)
param malwareScanCapGbPerMonth int = 5000

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

output defenderPlanNames string[] = defenderPlans.outputs.planNames
