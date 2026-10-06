using '../failover.bicep'

// Regional failover (Phase 8): prod only, deployed by an operator during a declared West US 3 outage (runbook 08),
// never by the pipeline. Run a what-if first; failback undoes these changes by hand and through the pipeline.
param environmentName = 'prod'
param location = 'eastus'
// The prod primary plan runs 3 instances.
param appServicePlanCapacity = 3
param failoverActive = true
// primaryStorageAccountId is not set here: a parameter file cannot call subscription(), so the template default names
// the prod primary account as main.bicep does (rg-defenstack-prod-wus3, stwus3<uniqueString(subscription id, 'prod',
// 'westus3')>). Override it with --parameters primaryStorageAccountId=<id> only if that account was renamed; the
// East US blob endpoint is named <account>-eus-pe.
