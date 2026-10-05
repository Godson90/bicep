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
