using '../governance.bicep'

// Subscription governance (Phase 7): one file per subscription, deployed by an operator (runbook 07), never by
// the pipeline. When dev and prod share a subscription, this one file covers both; another subscription gets its own copy.
// Contact addresses are not committed: set SECURITY_CONTACT_EMAILS (semicolon-separated) before the deployment.
// Unset, the list is empty and Azure refuses the deployment (at least one address is required).
param securityContactEmails = filter(
  map(split(readEnvironmentVariable('SECURITY_CONTACT_EMAILS', ''), ';'), email => trim(email)),
  email => !empty(email)
)
param malwareScanCapGbPerMonth = 5000
// Audit-first: switch to 'Default' only after the compliance review in runbook 07 is clean (ADR-027).
param denyEnforcement = 'DoNotEnforce'
param environments = [
  'dev'
  'prod'
]
// The admin groups get the DefenStack JIT Requester role at their primary regional resource group. Keep each value
// equal to adminGroupObjectId in params/<env>.bicepparam (runbook 03, section 4); empty skips that environment.
param adminGroupObjectIds = {
  dev: ''
  prod: ''
}
// The legacy waiver ends here; extend it only with a dated reason in runbook 01a.
param legacyResourceGroupName = 'defenStack'
param legacyWaiverExpiresOn = '2027-03-31'
