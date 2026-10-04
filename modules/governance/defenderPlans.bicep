// Microsoft Defender for Cloud plans for the whole subscription (Phase 7). Deployed by an operator through
// governance.bicep, never by the pipeline (ADR-026).
targetScope = 'subscription'

@description('Monthly cap, in GB per storage account, on Defender for Storage on-upload malware scanning, which is billed per GB scanned. -1 removes the cap.')
@minValue(-1)
param malwareScanCapGbPerMonth int = 5000

// One entry per plan, in deployment order. A plan with no subPlan or extensions takes Azure's current default.
var plans = [
  {
    // Servers Plan 2 with agentless disk scanning (Plan 2 is also what JIT VM access needs). Azure VMs reach
    // Defender for Endpoint through the integration Defender turns on by default, so MdeDesignatedSubscription,
    // which designates a subscription for directly onboarded non-Azure machines, stays off (ADR-026).
    name: 'VirtualMachines'
    properties: {
      pricingTier: 'Standard'
      subPlan: 'P2'
      extensions: [
        {
          name: 'AgentlessVmScanning'
          isEnabled: 'True'
        }
      ]
    }
  }
  {
    name: 'AppServices'
    properties: {
      pricingTier: 'Standard'
    }
  }
  {
    // Defender for Storage (per account): every upload is scanned for malware up to the monthly cap, and
    // sensitive data discovery is a separate extension.
    name: 'StorageAccounts'
    properties: {
      pricingTier: 'Standard'
      subPlan: 'DefenderForStorageV2'
      extensions: [
        {
          name: 'OnUploadMalwareScanning'
          isEnabled: 'True'
          additionalExtensionProperties: {
            CapGBPerMonthPerStorageAccount: string(malwareScanCapGbPerMonth)
          }
        }
        {
          name: 'SensitiveDataDiscovery'
          isEnabled: 'True'
        }
      ]
    }
  }
  {
    name: 'KeyVaults'
    properties: {
      pricingTier: 'Standard'
    }
  }
  {
    // Defender for Resource Manager.
    name: 'Arm'
    properties: {
      pricingTier: 'Standard'
    }
  }
  {
    // Defender CSPM.
    name: 'CloudPosture'
    properties: {
      pricingTier: 'Standard'
    }
  }
]

// The pricing API rejects concurrent updates in one subscription ("Another update operation is in progress"),
// so the plans are set one at a time.
@batchSize(1)
resource pricings 'Microsoft.Security/pricings@2024-01-01' = [for plan in plans: {
  name: plan.name
  properties: plan.properties
}]

output planNames string[] = [for (plan, index) in plans: pricings[index].name]
