# Phase 5: App and Data Resilience (RA-GZRS, Warm-Standby Read, Application Insights, Deploy-Time Secrets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each region's data and secrets survive the failures the design plans for, and make the app observable:
- RA-GZRS for the prod primary storage account, with a read-only warm-standby path to its geo-replica;
- one Entra-only Application Insights component per region;
- App Service default-deny restrictions;
- regional Key Vaults kept in sync by deploy-time secrets.

It also closes the Phase 4 follow-up in the Front Door approval script.

**Architecture:**
- **Storage.** `modules/regionStamp.bicep` picks `Standard_RAGZRS` for the prod primary account (`Standard_GRS` for the warm standby, `Standard_LRS` for dev).
  - `modules/storageSecondaryEndpoint.bicep` gives the East US stamp a `blob_secondary` private endpoint on the primary account.
  - `modules/storageReaderAssignment.bicep`, deployed into the primary resource group by `main.bicep`, grants the East US App Service identity Storage Blob Data Reader on the primary container.
- **Application Insights.** `modules/appInsights.bicep` creates one workspace-based component per region, with local auth disabled. `modules/appInsightsPublisher.bicep` grants each App Service identity Monitoring Metrics Publisher on its own component. `modules/appService.bicep` gets the connection string and Entra auth settings, plus default-deny restrictions.
- **Secrets.** `modules/keyVault.bicep` writes a `@secure()` `secrets` object as `Microsoft.KeyVault/vaults/secrets`. `main.bicep` passes the same `keyVaultSecrets` to every stamp. `deploy.yml` builds it from the `KEYVAULT_SECRETS_JSON` environment secret through `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`.
- **Approval script.** `scripts/Approve-FrontDoorPrivateEndpoints.ps1` now refuses a matching request when no Front Door origin references the app.

**Tech Stack:** Bicep CLI 0.47.16, Azure CLI 2.90+, Windows PowerShell 5.1 / pwsh 7, Pester 5.x, PSRule.Rules.Azure 1.47.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`. The relevant parts are §3 "Identity and secrets" and "Data and application resilience", §5 Phase 5, and §6 documentation standard.

This plan builds on Phase 4 (`docs/superpowers/plans/2026-10-01-phase4-ingress.md`). The branch `phase5-app-data` is stacked on `phase4-ingress` (commit `f251b00`).

**Verification status of this plan:** every Bicep module, test, script, workflow and document below was prototyped and run before the plan was written. The reference commits are local branches, not for merge: `phase5-proto-t1` … `phase5-proto-t4` (the state after Tasks 1–4) and `phase5-prototype` (the state after Task 5).
- `bicep lint` and `bicep build` are clean for every file.
- `main.json` is in sync.
- The full Pester suite passes: 335 → **345** (Task 1) → **357** (Task 2) → **371** (Task 3) → **374** (Task 4) → **383** (Task 5).
- `Invoke-PSRule` reports 0 failures: **808** results after Task 1, **871** from Task 2 on.
- `deploy.yml` parses as YAML.

The embedded content is that verified content. Transcribe it exactly.

## Global Constraints

- **User decisions (binding, taken when this plan was written):**
  - **Deploy-time secrets:** values come from the GitHub environment secret `KEYVAULT_SECRETS_JSON` and are written to every regional vault through Azure Resource Manager (ADR-019).
  - **One Application Insights component per region** (ADR-021).
  - **Prod primary storage is RA-GZRS; the East US stamp reads it through a `blob_secondary` private endpoint** (ADR-020).
  - **Fold in the Phase 4 follow-up:** the approval script refuses a matching request when no Front Door origin references the app.
- **Spec values (verbatim):**
  - "A regional Key Vault per stamp, synced by the pipeline. Keep RBAC, purge protection and private endpoints; add a delete lock."
  - "Storage: prod **RA-GZRS** (geo-copy to East US) plus the F7 data protection. The DR stamp consumes it through a private endpoint on the secondary endpoint (`blob-secondary` group ID)."
  - "App Service: P-v3 zone-redundant in the primary (capacity ≥3), minimum instances in DR."
  - "Application Insights, workspace-based, ingesting through AMPLS." AMPLS is Phase 6, so ingestion stays public until then.
  - The Phase 5 doc is `05-app-and-data.md` ("secret sync, restore from soft delete/PITR").
  - The Azure sub-resource for the spec's `blob-secondary` is `blob_secondary`.
- **Least privilege:** the warm standby gets **Storage Blob Data Reader** (`2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`), never a write role. The publisher role is **Monitoring Metrics Publisher** (`3913510d-42f4-4e42-8a64-420c390055eb`). Both are added to the pipeline identity's default `-DelegatableRoleDefinitionIds`, and the ABAC condition string changes with them.
- **Secrets never in Git:** no committed `.bicepparam` sets `keyVaultSecrets`. The converter never prints a value.
- **Unchanged:** F7 data protection; App Service `publicNetworkAccess: 'Disabled'`; regions and address plan; the Phase 4 approval rules other than the new refusal.
- **PSRule:** remove the global `Azure.Storage.UseReplication` exclusion, and suppress the rule only for `Standard_LRS` accounts (`field: sku.name`).
- **New API versions:**
  - `Microsoft.Insights/components@2020-02-02`
  - `Microsoft.KeyVault/vaults/secrets@2025-05-01`
  - Existing versions for private endpoints, storage and role assignments.
- **main.json is generated:** after any `.bicep` change, run `bicep build main.bicep`. Check with `diff --strip-trailing-cr <(bicep build main.bicep --stdout) main.json`.
- **Docs are mandatory:** runbooks use the 9-section template.
- **Tests must run on both shells:** Windows PowerShell 5.1 and pwsh 7.
- **No live Azure/Entra/GitHub commands; no push.** Script tests use a fake `az`.
- **Commit trailers:** `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
- **Build output:** never commit `modules/*.json`.
- **PowerShell editing gotchas:**
  - Never write Bicep through a double-quoted PowerShell string, because `${...}` is expanded and dropped.
  - In single-quoted strings, `''` is one `'`.
  - A helper `.ps1` containing non-ASCII characters (—, →, ↔, §) needs a UTF-8 BOM.
  - Read and write docs as UTF-8.

## Review Focus

These are inputs and conditions the spec implies but no offline test can fully exercise, most likely first:

1. **Azure rejects RA-GZRS together with point-in-time restore or change feed** on the prod primary account. Only the first prod deployment exercises this combination. The offline protection is the Task 1 SKU test plus runbook 05 §4 step 3 (validate with prod params) and the §9 row, which says what to change and that ADR-020 must be updated.
2. **The Azure Resource Manager secret write to a private, RBAC-mode vault fails, or a secret name or value is malformed.** Pinned by the Task 3 converter tests (invalid JSON, arrays, bad names, empty or non-string values, values never echoed) and runbook 05 §9 (the `Forbidden` row).
3. **A secret ends up in Git or in a log.** Pinned by the Task 3 tests "never sets keyVaultSecrets in a committed parameter file" and "reports names, never values", "never echoes a value in an error message", and "always deletes the secrets file".
4. **The warm standby gets write access to primary data, or the read endpoint appears in a stamp that is not the warm standby.** Pinned by the Task 1 tests "grants Storage Blob Data Reader, never a write role" and "deployed only by a stamp that is given a primary account".
5. **Telemetry is silently lost because key-based ingestion is disabled but the identity lacks the role.** Pinned by the Task 2 tests on `DisableLocalAuth`, the `Authorization=AAD` app setting and the publisher assignment wiring, plus runbook 05 §6.

Known coverage gaps:
- PSRule never sees the prod RA-GZRS account together with the warm-standby read endpoint in one expansion, and never sees a non-empty secrets object.
- The jump host is still not evaluated by PSRule (Phase 3).

## Execution Notes

- **Full suite:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`. It prints `Tests Passed: N, Failed: 0`.
- **Some files only:**

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { `$f = @('tests/StorageResilience.Tests.ps1'); & ./tests/Invoke-Tests.ps1 -Path `$f }"
  ```

- **PSRule:**

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
  ```

- **YAML check:** `powershell.exe -NoProfile -Command "Import-Module powershell-yaml; ConvertFrom-Yaml (Get-Content .github/workflows/deploy.yml -Raw) | Out-Null; 'YAML-OK'"`

## File Map

| File | Responsibility | Task |
|---|---|---|
| `modules/storageSecondaryEndpoint.bicep`, `modules/storageReaderAssignment.bicep` (new) | Warm-standby `blob_secondary` private endpoint; Storage Blob Data Reader on the primary container | 1 |
| `modules/regionStamp.bicep` (replace in Tasks 1, 2, 3) | Storage SKU, secondary endpoint, outputs (1); App Insights wiring (2); secrets (3) | 1, 2, 3 |
| `main.bicep` (replace in Tasks 1 and 3), `main.json` (regenerate) | Secondary-stamp storage inputs and the reader module (1); `keyVaultSecrets` (3) | 1, 3 |
| `ps-rule.yaml`, `.ps-rule/Suppression.Rule.yaml` (replace) | Drop the replication exclusion; LRS-only suppression | 1 |
| `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Scripts.Tests.ps1` (replace in Tasks 1 and 2) | Delegatable roles and ABAC condition | 1, 2 |
| `tests/StorageResilience.Tests.ps1` (new), `tests/RegionStamp.Tests.ps1` (replace) | Task 1 tests | 1 |
| `modules/appInsights.bicep`, `modules/appInsightsPublisher.bicep`, `tests/AppInsights.Tests.ps1` (new); `modules/appService.bicep` (replace) | Per-region component, publisher role, App Service settings and default-deny | 2 |
| `modules/keyVault.bicep` (replace), `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`, `tests/KeyVaultSecrets.Tests.ps1` (new), `.github/workflows/deploy.yml` (replace) | Deploy-time secrets | 3 |
| `scripts/Approve-FrontDoorPrivateEndpoints.ps1`, `tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1` (replace) | Refuse when no origin references the app | 4 |
| `docs/runbooks/05-app-and-data.md`, `docs/decisions/ADR-019/020/021-*` (new); `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/00-*`, `00b-*`, `01-*`, `04-*`, `README.md` (edit); `tests/Docs.Tests.ps1` (replace) | Phase 5 docs | 5 |

---

### Task 1: RA-GZRS for the prod primary account and the warm-standby read path

**Files:**
- Create: `modules/storageSecondaryEndpoint.bicep`, `modules/storageReaderAssignment.bicep`, `tests/StorageResilience.Tests.ps1`
- Replace: `modules/regionStamp.bicep`, `main.bicep`, `ps-rule.yaml`, `.ps-rule/Suppression.Rule.yaml`, `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Scripts.Tests.ps1`, `tests/RegionStamp.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes (Phases 1–4):**
  - Stamp variables `isProd` and `isPrimary`, module symbols `storage`, `spokeNetwork` and `appService`, and parameter `privateDnsZoneIds.blob`.
  - The storage module outputs `id`, `name` and `blobContainerName`.
  - `main.bicep` symbols `primaryStamp` and `secondaryStamp`, and variables `primaryResourceGroupName` and `secondaryRegionCode`.
- **Produces:**
  - `storageSecondaryEndpoint.bicep(location, primaryStorageAccountId, primaryStorageAccountName, privateEndpointSubnetId, blobPrivateDnsZoneId)`.
  - `storageReaderAssignment.bicep(storageAccountName, storageContainerName, readerPrincipalId, readerAppServiceName)`.
  - Stamp params `primaryStorageAccountId = ''` and `primaryStorageAccountName = ''`.
  - Stamp module deployment `storage-secondary-endpoint`.
  - Stamp outputs `storageAccountId`, `storageContainerName` and `appServicePrincipalId`.
  - `main.bicep` module symbol `secondaryStorageReader`.
  - The delegatable roles gain `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`.

- [ ] **Step 1: Confirm the branch**

  The worktree `.claude/worktrees/phase5-app-data` is on branch `phase5-app-data` at `f251b00` plus this plan's commit. Check it with `git log --oneline -2`.

- [ ] **Step 2: Write the failing tests**

  Create `tests/StorageResilience.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $endpointTemplate = Get-BicepTemplate -RelativePath 'modules/storageSecondaryEndpoint.bicep'
      $endpoint = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1
      $endpointDns = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' | Select-Object -First 1
      $readerTemplate = Get-BicepTemplate -RelativePath 'modules/storageReaderAssignment.bicep'
      $reader = Get-TemplateResource -Template $readerTemplate -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
      $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
      $main = Get-BicepTemplate -RelativePath 'main.bicep'
  }

  Describe 'Storage redundancy (Phase 5)' {
      It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev' {
          (Get-ModuleDeployment -Template $stamp -Name 'storage').properties.parameters.storageAccountSkuName |
              Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
      }
  }

  Describe 'Warm-standby read endpoint on the primary geo-replica (Phase 5)' {
      It 'connects to the primary account through its read-only blob_secondary sub-resource' {
          $connection = $endpoint.properties.privateLinkServiceConnections[0]
          $connection.properties.privateLinkServiceId | Should -Be "[parameters('primaryStorageAccountId')]"
          @($connection.properties.groupIds) | Should -Be @('blob_secondary')
          $endpoint.name | Should -Be "[format('{0}-secondary-pe', parameters('primaryStorageAccountName'))]"
      }

      It 'registers the <account>-secondary name in the shared blob zone' {
          $endpointDns.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId | Should -Be "[parameters('blobPrivateDnsZoneId')]"
      }

      It 'is deployed only by a stamp that is given a primary account (the warm standby)' {
          $module = Get-ModuleDeployment -Template $stamp -Name 'storage-secondary-endpoint'
          $module.condition | Should -Be "[not(empty(parameters('primaryStorageAccountId')))]"
          $module.properties.parameters.privateEndpointSubnetId.value | Should -Be "[reference('spokeNetwork').outputs.privateEndpointSubnetId.value]"
          $module.properties.parameters.blobPrivateDnsZoneId.value | Should -Be "[parameters('privateDnsZoneIds').blob]"
          $stamp.parameters.primaryStorageAccountId.defaultValue | Should -Be ''
      }

      It 'is wired from the primary stamp outputs into the secondary stamp only' {
          $secondary = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStamp'
          $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
          $secondary.properties.parameters.primaryStorageAccountId.value | Should -Be "[reference('primaryStamp').outputs.storageAccountId.value]"
          $secondary.properties.parameters.primaryStorageAccountName.value | Should -Be "[reference('primaryStamp').outputs.storageAccountName.value]"
          $primary.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'primaryStorageAccountId'
      }

      It 'outputs what main needs from each stamp' {
          foreach ($output in 'storageAccountId', 'storageContainerName', 'appServicePrincipalId') {
              $stamp.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }

  Describe 'Warm-standby read-only data access (Phase 5)' {
      It 'grants Storage Blob Data Reader, never a write role, at container scope' {
          $readerTemplate.variables.storageBlobDataReaderRoleId | Should -Be '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
          $reader.properties.roleDefinitionId | Should -Match 'storageBlobDataReaderRoleId'
          $reader.scope | Should -Match 'containers'
          $reader.properties.principalType | Should -Be 'ServicePrincipal'
      }

      It 'is assigned in the primary resource group to the warm-standby App Service identity, only with the secondary region' {
          $module = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStorageReader'
          $module.condition | Should -Be "[parameters('deploySecondaryRegion')]"
          $module.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $module.properties.parameters.readerPrincipalId.value | Should -Be "[reference('secondaryStamp').outputs.appServicePrincipalId.value]"
          $module.properties.parameters.storageAccountName.value | Should -Be "[reference('primaryStamp').outputs.storageAccountName.value]"
      }
  }

  Describe 'Replication rule baseline (Phase 5)' {
      It 'no longer excludes Azure.Storage.UseReplication globally' {
          Get-Content (Get-RepoPath 'ps-rule.yaml') -Raw | Should -Not -Match 'Azure\.Storage\.UseReplication'
      }

      It 'suppresses it only for locally redundant (dev) accounts' {
          $text = Get-Content (Get-RepoPath '.ps-rule/Suppression.Rule.yaml') -Raw
          $text | Should -Match 'DefenStack\.DevLocallyRedundantStorage'
          $text | Should -Match 'field: sku\.name\s+equals: Standard_LRS'
      }
  }
  ```

  Replace `tests/RegionStamp.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
      function Get-StampModuleParameters([string]$Name) {
          (Get-ModuleDeployment -Template $stamp -Name $Name).properties.parameters
      }
  }

  Describe 'Region stamp naming' {
      It 'names every resource with environment and region so stamps never collide' {
          foreach ($key in 'hubVnet', 'spokeVnet', 'firewall', 'firewallPolicy', 'firewallPublicIp', 'appServicePlan', 'appService') {
              $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
          }
      }

      It 'derives globally unique names from subscription, environment, and region' {
          $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
          $stamp.variables.names.storageAccount | Should -Be "[format('st{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
          $stamp.variables.names.keyVault | Should -Be "[format('kv-{0}-{1}', parameters('regionCode'), variables('nameSuffix'))]"
      }

      It 'passes the stamp names to the modules' {
          (Get-StampModuleParameters 'app-service').appServicePlanName.value | Should -Be "[variables('names').appServicePlan]"
          (Get-StampModuleParameters 'azure-firewall').firewallName.value | Should -Be "[variables('names').firewall]"
      }
  }

  Describe 'Region stamp availability' {
      It 'deploys the firewall and its public IP across zones 1-3 in every stamp' {
          @($stamp.variables.availabilityZones) -join ',' | Should -Be '1,2,3'
          (Get-StampModuleParameters 'azure-firewall').availabilityZones.value | Should -Be "[variables('availabilityZones')]"
      }

      It 'makes the App Service plan zone-redundant with 3 instances only in the prod primary region' {
          $parameters = Get-StampModuleParameters 'app-service'
          $parameters.zoneRedundant.value | Should -Be "[and(variables('isProd'), variables('isPrimary'))]"
          $parameters.instanceCount | Should -Be "[if(and(variables('isProd'), variables('isPrimary')), createObject('value', 3), createObject('value', 1))]"
      }

      It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev (Phase 5)' {
          (Get-StampModuleParameters 'storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
      }

      It 'deploys the optional management VM in the primary region only' {
          (Get-ModuleDeployment -Template $stamp -Name 'virtual-machine').condition |
              Should -Be "[and(parameters('enableVirtualMachine'), variables('isPrimary'))]"
      }
  }

  Describe 'Region stamp wiring carried from Phase 0' {
      It 'passes the admin source ranges (Bastion subnet, VPN pool, extra managementSourceCidrs) to <_> (F1, Phase 3)' -ForEach 'spoke-network', 'virtual-machine' {
          (Get-StampModuleParameters $_).managementSourceCidrs.value | Should -Be "[variables('adminSourceCidrs')]"
      }

      It 'uses the address plan spoke range for both the spoke VNet and firewall sources (F5)' {
          (Get-StampModuleParameters 'azure-firewall').spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
          (Get-StampModuleParameters 'spoke-network').vnetAddressSpace.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
      }

      It 'derives private endpoint sources from the App Service and management subnet prefixes (F5)' {
          $value = (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value
          $value | Should -Match "addressPlan'\)\.appServiceIntegrationSubnetPrefix"
          $value | Should -Match "addressPlan'\)\.managementSubnetPrefix"
          $value | Should -Match "addressPlan'\)\.vpnClientAddressPool"
          $value | Should -Match 'additionalPrivateEndpointSourceCidrs'
      }

      It 'uses firewall threat intelligence Deny in prod and Alert in dev (F9)' {
          (Get-StampModuleParameters 'azure-firewall').threatIntelMode |
              Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
      }

      It 'enables Key Vault template deployment so az.getSecret() references resolve (F4)' {
          (Get-StampModuleParameters 'key-vault').enabledForTemplateDeployment.value | Should -BeExactly $true
      }

      It 'passes the container name from the storage module output (F11)' {
          (Get-StampModuleParameters 'network-integration').storageContainerName.value | Should -Match 'outputs.blobContainerName'
      }

      It 'registers private endpoints in the shared zones from the global layer' {
          (Get-StampModuleParameters 'private-connectivity').privateDnsZoneIds.value | Should -Be "[parameters('privateDnsZoneIds')]"
      }

      It 'locks the spoke VNet in prod only' {
          (Get-StampModuleParameters 'spoke-network').enableDeleteLock.value | Should -Be "[variables('isProd')]"
      }
  }

  Describe 'Region stamp outputs' {
      It 'exposes the VNets the entry point links to the shared DNS zones' {
          foreach ($output in 'hubVnetName', 'hubVnetId', 'spokeVnetName', 'spokeVnetId', 'appServiceHostName') {
              $stamp.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }

  Describe 'Region stamp firewall security (Phase 2)' {
      It 'deploys Azure Firewall Premium in every stamp' {
          (Get-StampModuleParameters 'azure-firewall').firewallTier.value | Should -Be 'Premium'
      }

      It 'runs IDPS in Deny in prod and Alert in dev' {
          (Get-StampModuleParameters 'azure-firewall').idpsMode |
              Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
      }

      It 'limits OS update egress to the management subnet' {
          @((Get-StampModuleParameters 'azure-firewall').managementAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
      }

      It 'locks the hub VNet, Key Vault and firewall resources in prod only (<_>)' -ForEach 'hub-network', 'key-vault', 'azure-firewall' {
          (Get-StampModuleParameters $_).enableDeleteLock.value | Should -Be "[variables('isProd')]"
      }
  }

  Describe 'Region stamp admin access (Phase 3)' {
      It 'derives admin sources from the Bastion subnet and VPN client pool, plus any extra managementSourceCidrs' {
          $stamp.variables.adminSourceCidrs |
              Should -Be "[concat(createArray(parameters('addressPlan').bastionSubnetPrefix, parameters('addressPlan').vpnClientAddressPool), parameters('managementSourceCidrs'))]"
      }

      It 'deploys <_> only when deployAdminAccess is true' -ForEach 'bastion', 'vpn-gateway' {
          (Get-ModuleDeployment -Template $stamp -Name $_).condition | Should -Be "[parameters('deployAdminAccess')]"
          $stamp.parameters.deployAdminAccess.defaultValue | Should -BeExactly $false
      }

      It 'uses VpnGw2AZ in prod and VpnGw1AZ in dev' {
          (Get-StampModuleParameters 'vpn-gateway').skuName |
              Should -Be "[if(variables('isProd'), createObject('value', 'VpnGw2AZ'), createObject('value', 'VpnGw1AZ'))]"
      }

      It 'deploys <_> after the firewall, whose DNS proxy the hub uses' -ForEach 'bastion', 'vpn-gateway' {
          @((Get-ModuleDeployment -Template $stamp -Name $_).dependsOn) | Should -Contain 'azureFirewall'
      }

      It 'spreads <_> across zones 1-3' -ForEach 'bastion', 'vpn-gateway' {
          (Get-StampModuleParameters $_).availabilityZones.value | Should -Be "[variables('availabilityZones')]"
      }

      It 'gives the gateway the region VPN client pool' {
          (Get-StampModuleParameters 'vpn-gateway').vpnClientAddressPool.value | Should -Be "[parameters('addressPlan').vpnClientAddressPool]"
      }

      It 'routes GatewaySubnet spoke traffic to the first usable firewall address, computed before the firewall exists' {
          $stamp.variables.firewallPrivateIp | Should -Be "[cidrHost(parameters('addressPlan').firewallSubnetPrefix, 3)]"
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.firewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
          $hub.spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
          @((Get-ModuleDeployment -Template $stamp -Name 'hub-network').dependsOn) | Should -Not -Contain 'azureFirewall'
      }

      It 'lets Bastion reach only the management subnet' {
          @((Get-StampModuleParameters 'hub-network').bastionTargetAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
      }

      It 'passes the Bastion and gateway subnet prefixes from the address plan' {
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.bastionSubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').bastionSubnetPrefix]"
          $hub.gatewaySubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').gatewaySubnetPrefix]"
      }

      It 'allows the VPN client pool through the firewall admin-access rules' {
          @((Get-StampModuleParameters 'azure-firewall').vpnClientAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').vpnClientAddressPool]")
      }

      It 'turns on gateway transit only with admin access, after the gateway is provisioned' {
          (Get-StampModuleParameters 'network-integration').useHubGateway.value | Should -Be "[parameters('deployAdminAccess')]"
          @((Get-ModuleDeployment -Template $stamp -Name 'network-integration').dependsOn) | Should -Contain 'vpnGateway'
      }

      It 'passes the admin group to the management VM' {
          (Get-StampModuleParameters 'virtual-machine').adminGroupObjectId.value | Should -Be "[parameters('adminGroupObjectId')]"
      }

      It 'outputs the Bastion and gateway names (empty without admin access) and the expected firewall IP' {
          $stamp.outputs.bastionName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').bastion, '')]"
          $stamp.outputs.vpnGatewayName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').vpnGateway, '')]"
          $stamp.outputs.expectedFirewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
      }

      It 'names Bastion and the gateway with environment and region' {
          foreach ($key in 'bastion', 'bastionPublicIp', 'vpnGateway', 'vpnGatewayPublicIp') {
              $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
          }
      }
  }

  Describe 'Region stamp ingress output (Phase 4)' {
      It 'outputs the App Service resource ID for the Front Door Private Link origin' {
          $stamp.outputs.appServiceId.value | Should -Be "[reference('appService').outputs.appServiceAppId.value]"
      }
  }
  ```

  Replace `tests/Scripts.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $scriptPath = Get-RepoPath 'scripts/New-GitHubDeploymentIdentity.ps1'
      $resourceGroups = @('rg-defenstack-dev-global', 'rg-defenstack-dev-wus3')

      # Shadows the Azure CLI for one test. $Responses maps a -like pattern (matched against the joined
      # arguments, first match wins) to the value to return; every call is recorded in $global:AzCalls.
      function Set-AzShadow([System.Collections.Specialized.OrderedDictionary]$Responses) {
          $global:AzCalls = [System.Collections.Generic.List[string]]::new()
          $global:FederatedCredentialPayloads = [System.Collections.Generic.List[string]]::new()
          $global:AzResponses = $Responses
          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              $global:LASTEXITCODE = 0
              if ($joined -like 'role definition create*') {
                  $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                  $global:RoleDefinitionPayload = Get-Content $file -Raw
              }
              if ($joined -like 'ad app federated-credential create*') {
                  $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                  $global:FederatedCredentialPayloads.Add((Get-Content $file -Raw))
              }
              foreach ($pattern in $global:AzResponses.Keys) {
                  if ($joined -like $pattern) { return $global:AzResponses[$pattern] }
              }
              return ''
          }
      }

      function Remove-AzShadow {
          Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
          Remove-Variable -Name AzResponses -Scope Global -ErrorAction SilentlyContinue
      }

      function New-BaseResponses {
          $responses = [ordered]@{}
          $responses['account show*tenantId*'] = '11111111-1111-1111-1111-111111111111'
          $responses['account show*'] = '22222222-2222-2222-2222-222222222222'
          $responses
      }
  }

  Describe 'New-GitHubDeploymentIdentity.ps1' {
      It 'exists and parses without errors' {
          $scriptPath | Should -Exist
          $tokens = $null
          $errors = $null
          [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
          $errors | Should -BeNullOrEmpty
      }

      It 'supports -WhatIf' {
          (Get-Command $scriptPath).Parameters.Keys | Should -Contain 'WhatIf'
      }

      It 'makes no Azure or Entra changes under -WhatIf' {
          Set-AzShadow (New-BaseResponses)
          try {
              & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
          }
          finally {
              Remove-AzShadow
          }
          $mutations = $global:AzCalls | Where-Object { $_ -match '\b(create|delete|update|reset|add|remove)\b' }
          $mutations | Should -BeNullOrEmpty
      }

      It 'rejects delegating privileged role <_>' -ForEach @(
          '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
          '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
          'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
          'b24988ac-6180-42a0-ab88-20f7382dd24c'
      ) {
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds $_ -WhatIf } |
                  Should -Throw -ExpectedMessage '*privileged*'
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'rejects a delegatable role ID that is not a GUID' {
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds 'Owner' -WhatIf } |
                  Should -Throw
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses to proceed when multiple applications share the display name' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = @('aaaaaaaa-1111-1111-1111-111111111111', 'bbbbbbbb-2222-2222-2222-222222222222')
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage '*Multiple Entra applications*'
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses an existing federated credential with a different subject' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
          $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
          $responses['*federated-credential list*'] = 'repo:someone-else/bicep:environment:dev'
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses an existing unconditioned RBAC Administrator assignment' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
          $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
          $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
          $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
          $responses['*role definition list*'] = 'existing-custom-role'
          $responses['*role assignment list*condition*'] = ''
          $responses['*role assignment list*'] = 'eeeeeeee-5555-5555-5555-555555555555'
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage '*unconditioned*'
          }
          finally {
              Remove-AzShadow
          }
      }

      Context 'when creating assignments (non-WhatIf run against the shadow)' {
          BeforeAll {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
              $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $creates = @($global:AzCalls | Where-Object { $_ -like 'role assignment create*' })
          }

          It 'assigns the subscription deployment role at subscription scope only' {
              $deploymentAssignments = @($creates | Where-Object { $_ -like "*--role DefenStack Subscription Deployment Operator*" })
              $deploymentAssignments.Count | Should -Be 1
              $deploymentAssignments[0] | Should -BeLike '*--scope /subscriptions/22222222-2222-2222-2222-222222222222 *'
          }

          It 'assigns Contributor and constrained RBAC Administrator on each resource group, never at subscription scope' {
              foreach ($resourceGroup in $resourceGroups) {
                  $scope = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/$resourceGroup"
                  @($creates | Where-Object { $_ -like "*--role Contributor --scope $scope *" }).Count | Should -Be 1
                  @($creates | Where-Object { $_ -like "*--role Role Based Access Control Administrator --scope $scope *" }).Count | Should -Be 1
              }
              @($creates | Where-Object { $_ -like '*--role Contributor --scope /subscriptions/22222222-2222-2222-2222-222222222222 *' }).Count | Should -Be 0
          }

          It 'constrains RBAC Administrator with the exact ABAC condition for the delegatable roles (Storage Blob Data Contributor, Virtual Machine Administrator Login, Storage Blob Data Reader)' {
              $expected = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1}))"
              $rbacAdmin = @($creates | Where-Object { $_ -like '*--role Role Based Access Control Administrator*' })
              $rbacAdmin.Count | Should -Be 2
              foreach ($call in $rbacAdmin) {
                  # Literal match: the condition contains [ and ], which -like would treat as wildcards.
                  $call.Contains("--condition $expected --condition-version 2.0") | Should -BeTrue -Because $call
              }
          }
      }

      Context 'when creating the subscription deployment role (role definition missing)' {
          BeforeAll {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
              $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
              $responses['*role definition list*'] = ''
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $script:roleDefinitionPayload = $global:RoleDefinitionPayload | ConvertFrom-Json
          }

          It 'grants exactly the 9 deployment-operation and read-only actions, no wildcard' {
              $expectedActions = @(
                  'Microsoft.Resources/deployments/read',
                  'Microsoft.Resources/deployments/write',
                  'Microsoft.Resources/deployments/validate/action',
                  'Microsoft.Resources/deployments/whatIf/action',
                  'Microsoft.Resources/deployments/operations/read',
                  'Microsoft.Resources/deployments/operationstatuses/read',
                  'Microsoft.Resources/subscriptions/read',
                  'Microsoft.Resources/subscriptions/resourceGroups/read',
                  'Microsoft.Resources/subscriptions/operationresults/read'
              )
              @($script:roleDefinitionPayload.Actions | Sort-Object) | Should -Be @($expectedActions | Sort-Object)
              $script:roleDefinitionPayload.Actions | Should -Not -Contain '*'
          }

          It 'is assignable only at the subscription scope' {
              @($script:roleDefinitionPayload.AssignableScopes) | Should -Be @('/subscriptions/22222222-2222-2222-2222-222222222222')
          }
      }

      Context 'federated credentials for the plan and apply environments (Phase 2)' {
          It 'creates github-<env> and github-<env>-plan with their exact environment subjects' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 2
              ($credentials | Where-Object { $_.name -eq 'github-dev' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev'
              ($credentials | Where-Object { $_.name -eq 'github-dev-plan' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev-plan'
              foreach ($credential in $credentials) {
                  $credential.issuer | Should -BeExactly 'https://token.actions.githubusercontent.com'
                  @($credential.audiences) | Should -Be @('api://AzureADTokenExchange')
              }
          }

          It 'creates only github-staging for an environment not on the ungated-plan allowlist, with no plan credential (Final review D.7, fail closed)' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'staging' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-staging'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:staging'
          }

          It 'creates only github-prod for the prod environment, with no plan credential' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'prod' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-prod'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:prod'
          }

          It 'refuses an existing credential whose subject differs only in case' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*'] = 'repo:godson90/bicep:environment:dev'
              Set-AzShadow $responses
              try {
                  { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                      Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
              }
              finally {
                  Remove-AzShadow
              }
          }
      }
  }

  AfterAll {
      Remove-Variable -Name AzCalls, FederatedCredentialPayloads, RoleDefinitionPayload -Scope Global -ErrorAction SilentlyContinue
  }
  ```

- [ ] **Step 3: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected failures:
  - `bicep build failed for modules/storageSecondaryEndpoint.bicep`
  - the SKU expression mismatch
  - the ABAC condition string, which is missing `2a2b9908-...`
  - the ps-rule exclusion and suppression checks

- [ ] **Step 4: Create the two modules**

  Create `modules/storageSecondaryEndpoint.bicep`:

  ```bicep
  // Warm-standby read access to the primary region's RA-GZRS storage through its read-only secondary endpoint.

  @description('Azure region for the private endpoint (the warm-standby region).')
  param location string

  @description('Resource ID of the primary region storage account (RA-GZRS).')
  param primaryStorageAccountId string

  @description('Primary region storage account name, used for deterministic naming.')
  @minLength(3)
  @maxLength(24)
  param primaryStorageAccountName string

  @description('Private endpoint subnet in the warm-standby spoke.')
  param privateEndpointSubnetId string

  @description('Shared privatelink.blob zone resource ID; the secondary endpoint registers as <account>-secondary.')
  param blobPrivateDnsZoneId string

  resource secondaryEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
    name: '${primaryStorageAccountName}-secondary-pe'
    location: location
    properties: {
      privateLinkServiceConnections: [
        {
          name: 'blob-secondary'
          properties: {
            privateLinkServiceId: primaryStorageAccountId
            groupIds: [
              'blob_secondary'
            ]
          }
        }
      ]
      subnet: {
        id: privateEndpointSubnetId
      }
    }
  }

  resource secondaryEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
    parent: secondaryEndpoint
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'blob-secondary'
          properties: {
            privateDnsZoneId: blobPrivateDnsZoneId
          }
        }
      ]
    }
  }

  output id string = secondaryEndpoint.id
  ```

  Create `modules/storageReaderAssignment.bicep`:

  ```bicep
  // Read-only data access for another region's App Service identity on this region's application container.

  @description('Storage account name in this resource group.')
  @minLength(3)
  @maxLength(24)
  param storageAccountName string

  @description('Blob container the reader may read.')
  @minLength(3)
  @maxLength(63)
  param storageContainerName string

  @description('Principal ID of the App Service managed identity that reads the container.')
  param readerPrincipalId string

  @description('Name of the App Service that owns the identity, used to make the assignment GUID deterministic.')
  @minLength(2)
  @maxLength(60)
  param readerAppServiceName string

  var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

  resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
    name: storageAccountName

    resource blobService 'blobServices' existing = {
      name: 'default'

      resource container 'containers' existing = {
        name: storageContainerName
      }
    }
  }

  resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: guid(storageAccount.id, storageContainerName, readerAppServiceName, storageBlobDataReaderRoleId)
    scope: storageAccount::blobService::container
    properties: {
      principalId: readerPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    }
  }
  ```

- [ ] **Step 5: Wire them in**

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet } from 'types.bicep'

  @description('Deployment environment.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Role of this region in the active/passive design. Only the primary gets zone-redundant App Service capacity and the optional management VM.')
  @allowed([
    'primary'
    'secondary'
  ])
  param regionRole string

  @description('Azure region for this stamp.')
  param location string

  @description('Short lowercase region code used in resource names, for example wus3 or eus.')
  @minLength(2)
  @maxLength(4)
  param regionCode string

  @description('Hub and spoke address plan for this region.')
  param addressPlan regionAddressPlan

  @description('Central Log Analytics workspace resource ID from the global layer.')
  param logAnalyticsWorkspaceId string

  @description('Shared private DNS zone resource IDs from the global layer.')
  param privateDnsZoneIds privateDnsZoneSet

  @description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('Relative path probed by App Service health check.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM (primary region only).')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in this region. The warm standby leaves it off until failover.')
  param deployAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  var isProd = environmentName == 'prod'
  var isPrimary = regionRole == 'primary'
  var nameSuffix = uniqueString(subscription().id, environmentName, location)
  var availabilityZones = [
    '1'
    '2'
    '3'
  ]
  var names = {
    hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
    spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
    firewall: 'afw-defenstack-${environmentName}-${regionCode}'
    firewallPolicy: 'afwp-defenstack-${environmentName}-${regionCode}'
    firewallPublicIp: 'pip-afw-defenstack-${environmentName}-${regionCode}'
    storageAccount: 'st${regionCode}${nameSuffix}'
    keyVault: 'kv-${regionCode}-${nameSuffix}'
    appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
    appService: 'app-defenstack-${environmentName}-${regionCode}-${take(nameSuffix, 6)}'
    virtualMachine: 'vm${regionCode}${take(nameSuffix, 7)}'
    bastion: 'bas-defenstack-${environmentName}-${regionCode}'
    bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
    vpnGateway: 'vpng-defenstack-${environmentName}-${regionCode}'
    vpnGatewayPublicIp: 'pip-vpng-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module keyVault 'keyVault.bicep' = {
    name: 'key-vault'
    params: {
      location: location
      keyVaultName: names.keyVault
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      enablePurgeProtection: true
      enabledForTemplateDeployment: true
      enableDeleteLock: isProd
    }
  }

  module hubNetwork 'hubNetwork.bicep' = {
    name: 'hub-network'
    params: {
      location: location
      vnetName: names.hubVnet
      addressSpace: addressPlan.hubAddressSpace
      firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
      bastionSubnetAddressPrefix: addressPlan.bastionSubnetPrefix
      gatewaySubnetAddressPrefix: addressPlan.gatewaySubnetPrefix
      firewallPrivateIp: firewallPrivateIp
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      bastionTargetAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      enableDeleteLock: isProd
    }
  }

  module azureFirewall 'azureFirewall.bicep' = {
    name: 'azure-firewall'
    params: {
      location: location
      firewallName: names.firewall
      firewallPolicyName: names.firewallPolicy
      publicIpName: names.firewallPublicIp
      firewallSubnetId: hubNetwork.outputs.firewallSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      managementAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      vpnClientAddressPrefixes: [
        addressPlan.vpnClientAddressPool
      ]
      allowedOutboundFqdns: allowedOutboundFqdns
      threatIntelMode: isProd ? 'Deny' : 'Alert'
      availabilityZones: availabilityZones
      firewallTier: 'Premium'
      idpsMode: isProd ? 'Deny' : 'Alert'
      enableDeleteLock: isProd
    }
  }

  module spokeNetwork 'spokeNetwork.bicep' = {
    name: 'spoke-network'
    params: {
      location: location
      vnetName: names.spokeVnet
      firewallPrivateIp: azureFirewall.outputs.privateIp
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      vnetAddressSpace: addressPlan.spokeAddressSpace
      privateEndpointSubnetAddressPrefix: addressPlan.privateEndpointSubnetPrefix
      appServiceIntegrationSubnetAddressPrefix: addressPlan.appServiceIntegrationSubnetPrefix
      virtualMachineSubnetAddressPrefix: addressPlan.managementSubnetPrefix
      approvedPrivateEndpointSourceCidrs: concat([
        addressPlan.appServiceIntegrationSubnetPrefix
        addressPlan.managementSubnetPrefix
        addressPlan.vpnClientAddressPool
      ], additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  module appService 'appService.bicep' = {
    name: 'app-service'
    params: {
      location: location
      appServiceAppName: names.appService
      appServicePlanName: names.appServicePlan
      environmentType: environmentName
      vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      healthCheckPath: healthCheckPath
      zoneRedundant: isProd && isPrimary
      instanceCount: isProd && isPrimary ? 3 : 1
    }
  }

  module virtualMachine 'virtualMachine.bicep' = if (enableVirtualMachine && isPrimary) {
    name: 'virtual-machine'
    params: {
      location: location
      vmName: names.virtualMachine
      osType: virtualMachineOsType
      subnetId: spokeNetwork.outputs.virtualMachineSubnetId
      adminUsername: virtualMachineAdminUsername
      adminSshPublicKey: virtualMachineAdminSshPublicKey
      adminPassword: virtualMachineAdminPassword
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      managementSourceCidrs: adminSourceCidrs
      adminGroupObjectId: adminGroupObjectId
    }
  }

  module bastion 'bastion.bicep' = if (deployAdminAccess) {
    name: 'bastion'
    params: {
      location: location
      bastionName: names.bastion
      publicIpName: names.bastionPublicIp
      subnetId: hubNetwork.outputs.bastionSubnetId
      availabilityZones: availabilityZones
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    // The hub resolves DNS through the firewall, so admin access waits for it.
    dependsOn: [
      azureFirewall
    ]
  }

  module vpnGateway 'vpnGateway.bicep' = if (deployAdminAccess) {
    name: 'vpn-gateway'
    params: {
      location: location
      gatewayName: names.vpnGateway
      publicIpNamePrefix: names.vpnGatewayPublicIp
      gatewaySubnetId: hubNetwork.outputs.gatewaySubnetId
      skuName: isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'
      availabilityZones: availabilityZones
      vpnClientAddressPool: addressPlan.vpnClientAddressPool
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    dependsOn: [
      azureFirewall
    ]
  }

  module networkIntegration 'networkIntegration.bicep' = {
    name: 'network-integration'
    params: {
      hubVnetName: names.hubVnet
      hubVnetId: hubNetwork.outputs.id
      spokeVnetName: names.spokeVnet
      spokeVnetId: spokeNetwork.outputs.id
      storageAccountName: names.storageAccount
      storageAccountId: storage.outputs.id
      storageContainerName: storage.outputs.blobContainerName
      appServicePrincipalId: appService.outputs.appServicePrincipalId
      appServiceName: names.appService
      useHubGateway: deployAdminAccess
    }
    // Gateway transit on the peering needs a provisioned gateway.
    dependsOn: [
      vpnGateway
    ]
  }

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
    }
  }

  module privateConnectivity 'privateConnectivity.bicep' = {
    name: 'private-connectivity'
    params: {
      location: location
      storageAccountId: storage.outputs.id
      storageAccountName: names.storageAccount
      appServiceId: appService.outputs.appServiceAppId
      appServiceName: names.appService
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      keyVaultId: keyVault.outputs.id
      keyVaultName: names.keyVault
      privateDnsZoneIds: privateDnsZoneIds
    }
  }

  output hubVnetName string = names.hubVnet
  output hubVnetId string = hubNetwork.outputs.id
  output spokeVnetName string = names.spokeVnet
  output spokeVnetId string = spokeNetwork.outputs.id
  output firewallPrivateIp string = azureFirewall.outputs.privateIp
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceId string = appService.outputs.appServiceAppId
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  ```

  Replace `main.bicep`:

  ```bicep
  targetScope = 'subscription'

  import { regionAddressPlan, privateDnsZoneSet } from 'modules/types.bicep'

  @description('Deployment environment. Selects resource group names, redundancy, and deletion protection.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Primary (active) Azure region. Each allowed region has a short code in regionCodes.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param primaryLocation string = 'westus3'

  @description('Secondary (warm standby) Azure region, the platform pair of the primary.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param secondaryLocation string = 'eastus'

  @description('Deploy the secondary region stamp. Prod enables it; dev runs primary-only to halve cost.')
  param deploySecondaryRegion bool = false

  @description('Address plan for the primary region.')
  param primaryAddressPlan regionAddressPlan

  @description('Address plan for the secondary region. Required when deploySecondaryRegion is true.')
  param secondaryAddressPlan regionAddressPlan?

  @description('Approved outbound HTTPS destinations for both regions. Empty keeps application traffic denied.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges allowed to reach private endpoints over HTTPS in every region.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('Extra CIDR ranges allowed to administer management VMs over SSH/RDP, beyond the AzureBastionSubnet and VPN client pool of each region.')
  param managementSourceCidrs array = []

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the primary region.')
  param deployPrimaryAdminAccess bool = true

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the secondary region. Off in steady state; turned on during failover.')
  param deploySecondaryAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Custom domain served by Front Door, for example app.example.com, hosted at an external DNS provider. Empty serves only the azurefd.net hostname.')
  param customDomainHostName string = ''

  @description('Relative path probed by App Service health check in every region.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM in the primary region.')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  var isProd = environmentName == 'prod'
  var regionCodes = {
    westus3: 'wus3'
    eastus: 'eus'
  }
  var primaryRegionCode = regionCodes[toLower(primaryLocation)]
  var secondaryRegionCode = regionCodes[toLower(secondaryLocation)]
  var globalResourceGroupName = 'rg-defenstack-${environmentName}-global'
  var primaryResourceGroupName = 'rg-defenstack-${environmentName}-${primaryRegionCode}'
  var secondaryResourceGroupName = 'rg-defenstack-${environmentName}-${secondaryRegionCode}'
  var privateDnsZoneNames privateDnsZoneSet = {
    blob: 'privatelink.blob.${environment().suffixes.storage}'
    sites: 'privatelink.azurewebsites.net'
    vault: 'privatelink.vaultcore.azure.net'
  }

  // Shared layer: Log Analytics and private DNS zones. Resource groups are pre-created (runbook 01).
  module global 'modules/global.bicep' = {
    name: 'global-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      location: primaryLocation
      workspaceName: 'log-defenstack-${environmentName}'
      privateDnsZoneNames: privateDnsZoneNames
      workspaceReplicationLocation: isProd && deploySecondaryRegion ? secondaryLocation : ''
      enableDeleteLock: isProd
    }
  }

  module primaryStamp 'modules/regionStamp.bicep' = {
    name: 'region-${primaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'primary'
      location: primaryLocation
      regionCode: primaryRegionCode
      addressPlan: primaryAddressPlan
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      enableVirtualMachine: enableVirtualMachine
      virtualMachineOsType: virtualMachineOsType
      virtualMachineAdminUsername: virtualMachineAdminUsername
      virtualMachineAdminSshPublicKey: virtualMachineAdminSshPublicKey
      virtualMachineAdminPassword: virtualMachineAdminPassword
      deployAdminAccess: deployPrimaryAdminAccess
      adminGroupObjectId: adminGroupObjectId
    }
  }

  module secondaryStamp 'modules/regionStamp.bicep' = if (deploySecondaryRegion) {
    name: 'region-${secondaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'secondary'
      location: secondaryLocation
      regionCode: secondaryRegionCode
      addressPlan: secondaryAddressPlan!
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      deployAdminAccess: deploySecondaryAdminAccess
      primaryStorageAccountId: primaryStamp.outputs.storageAccountId
      primaryStorageAccountName: primaryStamp.outputs.storageAccountName
    }
  }

  // The warm-standby App Service may read (never write) the primary application container (ADR-020).
  module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion) {
    name: 'storage-reader-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      storageAccountName: primaryStamp.outputs.storageAccountName
      storageContainerName: primaryStamp.outputs.storageContainerName
      readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
      readerAppServiceName: secondaryStamp!.outputs.appServiceName
    }
  }

  var primaryVirtualNetworks = [
    {
      name: primaryStamp.outputs.hubVnetName
      id: primaryStamp.outputs.hubVnetId
    }
    {
      name: primaryStamp.outputs.spokeVnetName
      id: primaryStamp.outputs.spokeVnetId
    }
  ]
  var secondaryVirtualNetworks = deploySecondaryRegion
    ? [
        {
          name: secondaryStamp!.outputs.hubVnetName
          id: secondaryStamp!.outputs.hubVnetId
        }
        {
          name: secondaryStamp!.outputs.spokeVnetName
          id: secondaryStamp!.outputs.spokeVnetId
        }
      ]
    : []

  // Origins in failover order: the primary region first (priority 1), then the warm standby (priority 2).
  var primaryOrigin = {
    name: 'app-${primaryRegionCode}'
    appServiceId: primaryStamp.outputs.appServiceId
    hostName: primaryStamp.outputs.appServiceHostName
    location: primaryLocation
  }
  var secondaryOrigins = deploySecondaryRegion
    ? [
        {
          name: 'app-${secondaryRegionCode}'
          appServiceId: secondaryStamp!.outputs.appServiceId
          hostName: secondaryStamp!.outputs.appServiceHostName
          location: secondaryLocation
        }
      ]
    : []

  // Public ingress: one Front Door per environment in the global resource group, after both stamps exist.
  module frontDoor 'modules/frontDoor.bicep' = {
    name: 'front-door-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      profileName: 'afd-defenstack-${environmentName}'
      endpointName: 'fde-defenstack-${environmentName}'
      wafPolicyName: 'wafdefenstack${environmentName}'
      origins: concat([
        primaryOrigin
      ], secondaryOrigins)
      healthProbePath: healthCheckPath
      customDomainHostName: customDomainHostName
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      enableDeleteLock: isProd
    }
  }

  // Link every region's hub (firewall DNS proxy) and spoke to each shared zone.
  module privateDnsLinks 'modules/privateDnsZoneLinks.bicep' = [for zone in items(privateDnsZoneNames): {
    name: 'dns-links-${zone.key}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      zoneName: zone.value
      virtualNetworks: concat(primaryVirtualNetworks, secondaryVirtualNetworks)
    }
  }]

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output frontDoorProfileName string = frontDoor.outputs.profileName
  output globalResourceGroupName string = globalResourceGroupName
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
  ```

- [ ] **Step 6: Update PSRule and the pipeline identity defaults**

  Replace `ps-rule.yaml`:

  ```yaml
  # PSRule for Azure: https://azure.github.io/PSRule.Rules.Azure/
  include:
    module:
      - PSRule.Rules.Azure

  input:
    pathIgnore:
      - '**'
      - '!params/*.bicepparam'

  configuration:
    AZURE_BICEP_PARAMS_FILE_EXPANSION: true
    # Expanding main.bicep takes ~10 s once Phase 3 modules are included; the 5 s default times out.
    AZURE_BICEP_FILE_EXPANSION_TIMEOUT: 60

  rule:
    # Exclusions apply to every environment and target. Each must name the phase that resolves it or
    # the ADR that accepts it. Gaps that apply only to some targets (dev, the East US warm standby)
    # are suppressed per target in .ps-rule/Suppression.Rule.yaml instead.
    exclude:

      # ADR-002: no organization-wide tagging convention exists yet.
      - Azure.Resource.UseTags
      # ADR-004: zero-trust default-deny-all-inbound is the intended design for these NSGs.
      - Azure.NSG.DenyAllInbound
      # ADR-005: the VNet DNS proxy points at Azure Firewall's single private IP by design.
      - Azure.VNET.SingleDNS
      # ADR-006: no application code is deployed yet, so no dedicated health endpoint exists.
      - Azure.AppService.WebProbePath
  ```

  Replace `.ps-rule/Suppression.Rule.yaml`:

  ```yaml
  ---
  # Synopsis: Dev and the East US warm standby run one App Service instance without zone redundancy (ADR-008).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.SingleInstanceAppServicePlans
  spec:
    rule:
      - Azure.AppService.AvailabilityZone
      - Azure.AppService.PlanInstanceCount
    if:
      name: '.'
      in:
        - asp-defenstack-dev-wus3
        - asp-defenstack-prod-eus
  ---
  # Synopsis: The dev workspace is single-region; only prod replicates to the secondary region (ADR-008).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.DevWorkspaceReplication
  spec:
    rule:
      - Azure.Log.Replication
    if:
      name: '.'
      equals: log-defenstack-dev
  ---
  # Synopsis: Dev firewall policy runs threat intelligence in Alert mode; prod runs Deny (ADR-003).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.DevFirewallAlertMode
  spec:
    rule:
      - Azure.Firewall.PolicyMode
    if:
      name: '.'
      equals: afwp-defenstack-dev-wus3
  ---
  # Synopsis: Bastion must open SSH/RDP sessions to the management subnet; its NSG allows exactly that and denies all other SSH/RDP egress (ADR-013).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.BastionSessionEgress
  spec:
    rule:
      - Azure.NSG.LateralTraversal
    if:
      name: '.'
      in:
        - vnet-defenstack-dev-wus3-hub-bastion-nsg
        - vnet-defenstack-prod-wus3-hub-bastion-nsg
        - vnet-defenstack-prod-eus-hub-bastion-nsg
  ---
  # Synopsis: Dev storage is locally redundant; prod uses RA-GZRS (primary) and GRS (warm standby). Storage names are hashed, so the dev account is matched by SKU (ADR-008, ADR-020).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.DevLocallyRedundantStorage
  spec:
    rule:
      - Azure.Storage.UseReplication
    if:
      field: sku.name
      equals: Standard_LRS
  ```

  Replace `scripts/New-GitHubDeploymentIdentity.ps1`:

  ```powershell
  [CmdletBinding(SupportsShouldProcess)]
  param(
      [Parameter(Mandatory)]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^[-\w._()]{1,90}$')]
      [string[]]$ResourceGroupNames,

      [Parameter(Mandatory)]
      [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
      [string]$GitHubRepository,

      [Parameter(Mandatory)]
      [ValidatePattern('^[A-Za-z0-9_-]+$')]
      [string]$EnvironmentName,

      [Parameter()]
      [string]$SubscriptionId,

      [Parameter()]
      [ValidatePattern('^[A-Za-z0-9._-]{1,120}$')]
      [string]$DisplayName,

      [Parameter()]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
      [ValidateScript({
              # Owner, User Access Administrator, RBAC Administrator, Contributor: never delegable.
              $privileged = @(
                  '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
                  '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
                  'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
                  'b24988ac-6180-42a0-ab88-20f7382dd24c'
              )
              if ($privileged -contains $_.ToLowerInvariant()) { throw "Role definition $_ is privileged and cannot be delegated to the pipeline." }
              $true
          })]
      [string[]]$DelegatableRoleDefinitionIds = @(
          'ba92f5b4-2d11-453d-a403-e96b0029c9fe', # Storage Blob Data Contributor (app identity, container scope)
          '1c0163c0-47e6-4577-8991-ea5c82e286e4', # Virtual Machine Administrator Login (admin group, jump host; Phase 3)
          '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'  # Storage Blob Data Reader (warm-standby app on the primary container; Phase 5)
      ),

      [Parameter()]
      [switch]$GrantLockManagement,

      [Parameter()]
      [ValidateRange(0, 600)]
      [int]$RoleReplicationWaitSeconds = 20
  )

  $ErrorActionPreference = 'Stop'

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
      throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
  }

  if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
      $SubscriptionId = az account show --query id --output tsv
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
          throw 'No active Azure subscription was found. Run az login or provide -SubscriptionId.'
      }
  }

  $tenantId = az account show --subscription $SubscriptionId --query tenantId --output tsv
  if ($LASTEXITCODE -ne 0) {
      throw 'Unable to read the tenant ID for the subscription.'
  }

  if ([string]::IsNullOrWhiteSpace($DisplayName)) {
      $DisplayName = "gh-$($GitHubRepository.Replace('/', '-'))-$EnvironmentName-deploy"
  }

  $subscriptionScope = "/subscriptions/$SubscriptionId"
  $resourceGroupScopes = @($ResourceGroupNames | ForEach-Object { "$subscriptionScope/resourceGroups/$_" })
  # The deploy workflow's plan job runs in '<env>-plan' (no reviewers) only for the environments listed here;
  # every other environment's plan job runs in the gated '<env>' environment alongside apply, so it gets no
  # ungated '-plan' credential. Fail closed: an environment must be explicitly opted in to get an ungated plan
  # credential. Today only dev is opted in; prod (ADR-012) and any future environment (for example a 'staging')
  # get no '-plan' credential unless deliberately added here.
  $ungatedPlanEnvironments = @('dev')
  $credentialEnvironments = if ($ungatedPlanEnvironments -contains $EnvironmentName) { @($EnvironmentName, "$EnvironmentName-plan") } else { @($EnvironmentName) }

  Write-Host "Application: $DisplayName"
  Write-Host "Federated subjects: $(($credentialEnvironments | ForEach-Object { "repo:${GitHubRepository}:environment:$_" }) -join ', ')"
  Write-Host "Resource group scopes: $($resourceGroupScopes -join ', ')"

  # 1. Application registration (idempotent by exact display name match).
  $appMatches = @(az ad app list --display-name $DisplayName --query "[?displayName=='$DisplayName'].appId" --output tsv | Where-Object { $_ })
  if ($LASTEXITCODE -ne 0) {
      throw "Failed to query Entra applications named '$DisplayName'."
  }
  if ($appMatches.Count -gt 1) {
      throw "Multiple Entra applications are named '$DisplayName'. Resolve the duplicates or pass a unique -DisplayName."
  }
  $appId = if ($appMatches.Count -eq 1) { $appMatches[0] } else { $null }
  if ([string]::IsNullOrWhiteSpace($appId)) {
      if ($PSCmdlet.ShouldProcess($DisplayName, 'Create Entra application registration')) {
          $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId --output tsv
          if ($LASTEXITCODE -ne 0) { throw 'Failed to create the application registration.' }
      }
      else {
          $appId = '<new-application-id>'
      }
  }

  # 2. Service principal.
  $servicePrincipalId = $null
  if ($appId -ne '<new-application-id>') {
      $servicePrincipalId = az ad sp list --filter "appId eq '$appId'" --query '[0].id' --output tsv
  }
  if ([string]::IsNullOrWhiteSpace($servicePrincipalId)) {
      if ($PSCmdlet.ShouldProcess($appId, 'Create service principal')) {
          $servicePrincipalId = az ad sp create --id $appId --query id --output tsv
          if ($LASTEXITCODE -ne 0) { throw 'Failed to create the service principal.' }
      }
      else {
          $servicePrincipalId = '<new-service-principal-object-id>'
      }
  }

  # 3. Federated credentials bound to the GitHub environments; an existing one must have exactly the same subject.
  function Set-FederatedCredential {
      param(
          [string]$GitHubEnvironment
      )

      $credentialName = "github-$GitHubEnvironment"
      $subject = "repo:${GitHubRepository}:environment:$GitHubEnvironment"

      $existingSubject = $null
      if ($appId -ne '<new-application-id>') {
          $existingSubject = az ad app federated-credential list --id $appId --query "[?name=='$credentialName'].subject" --output tsv
      }
      if (-not [string]::IsNullOrWhiteSpace($existingSubject)) {
          # Entra matches subjects case-sensitively, so compare case-sensitively too.
          if ($existingSubject -cne $subject) {
              throw "Federated credential '$credentialName' exists with subject '$existingSubject', expected '$subject'. Delete it (az ad app federated-credential delete --id $appId --federated-credential-id $credentialName) and re-run."
          }
          Write-Host "Federated credential '$credentialName' already present."
          return
      }

      if ($PSCmdlet.ShouldProcess($subject, 'Create federated credential')) {
          $credentialFile = New-TemporaryFile
          try {
              @{
                  name        = $credentialName
                  issuer      = 'https://token.actions.githubusercontent.com'
                  subject     = $subject
                  audiences   = @('api://AzureADTokenExchange')
                  description = "GitHub Actions environment '$GitHubEnvironment' for $GitHubRepository"
              } | ConvertTo-Json | Set-Content -Path $credentialFile -Encoding ASCII

              az ad app federated-credential create --id $appId --parameters "@$credentialFile" --output none
              if ($LASTEXITCODE -ne 0) { throw "Failed to create the federated credential '$credentialName'." }
          }
          finally {
              Remove-Item $credentialFile -Force
          }
      }
  }

  foreach ($credentialEnvironment in $credentialEnvironments) {
      Set-FederatedCredential -GitHubEnvironment $credentialEnvironment
  }

  function Set-RoleAssignment {
      param(
          [string]$Role,
          [string]$Scope,
          [string]$Condition,
          [switch]$AllowReplicationRetry
      )

      $existing = $null
      if ($servicePrincipalId -notlike '<*>') {
          $existing = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].id' --output tsv
      }
      if (-not [string]::IsNullOrWhiteSpace($existing)) {
          if ($Condition) {
              $existingCondition = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].condition' --output tsv
              $normalizedExisting = ($existingCondition -replace '\s+', ' ').Trim()
              $normalizedDesired = ($Condition -replace '\s+', ' ').Trim()
              if ([string]::IsNullOrWhiteSpace($normalizedExisting)) {
                  throw "An unconditioned '$Role' assignment already exists at $Scope. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
              }
              if ($normalizedExisting -ne $normalizedDesired) {
                  throw "An existing '$Role' assignment at $Scope has a different condition than expected. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
              }
          }
          Write-Host "Role '$Role' already assigned at $Scope."
          return
      }

      if ($PSCmdlet.ShouldProcess($Scope, "Assign '$Role' to $servicePrincipalId")) {
          $arguments = @(
              'role', 'assignment', 'create',
              '--assignee-object-id', $servicePrincipalId,
              '--assignee-principal-type', 'ServicePrincipal',
              '--role', $Role,
              '--scope', $Scope,
              '--output', 'none'
          )
          if ($Condition) {
              $arguments += @('--condition', $Condition, '--condition-version', '2.0')
          }

          # A just-created custom role can take minutes to replicate before it can be assigned.
          $attempts = if ($AllowReplicationRetry) { 6 } else { 1 }
          for ($attempt = 1; $attempt -le $attempts; $attempt++) {
              az @arguments
              if ($LASTEXITCODE -eq 0) { return }
              if ($attempt -lt $attempts) {
                  Write-Host "Assignment of '$Role' failed (attempt $attempt of $attempts); waiting $RoleReplicationWaitSeconds s for role replication."
                  Start-Sleep -Seconds $RoleReplicationWaitSeconds
              }
          }
          throw "Failed to assign '$Role' at $Scope."
      }
  }

  function Set-CustomRole {
      param(
          [string]$Name,
          [string]$Description,
          [string[]]$Actions
      )

      $existingRole = az role definition list --name $Name --custom-role-only true --query '[0].name' --output tsv
      if (-not [string]::IsNullOrWhiteSpace($existingRole)) { return }

      if ($PSCmdlet.ShouldProcess($Name, 'Create custom role')) {
          $roleFile = New-TemporaryFile
          try {
              @{
                  Name             = $Name
                  Description      = $Description
                  Actions          = $Actions
                  NotActions       = @()
                  AssignableScopes = @($subscriptionScope)
              } | ConvertTo-Json | Set-Content -Path $roleFile -Encoding ASCII

              az role definition create --role-definition "@$roleFile" --output none
              if ($LASTEXITCODE -ne 0) { throw "Failed to create the custom role '$Name'." }
          }
          finally {
              Remove-Item $roleFile -Force
          }
      }
  }

  # 4. Subscription-scope deployments only (no resource rights): the entry point targets the subscription,
  #    while every resource lands in a pre-created resource group granted below.
  $deploymentRoleName = 'DefenStack Subscription Deployment Operator'
  Set-CustomRole -Name $deploymentRoleName -Description 'Run subscription-scope ARM deployments (validate, what-if, create) and read resource groups. Grants no resource permissions and cannot cancel or delete deployments.' -Actions @(
      'Microsoft.Resources/deployments/read',
      'Microsoft.Resources/deployments/write',
      'Microsoft.Resources/deployments/validate/action',
      'Microsoft.Resources/deployments/whatIf/action',
      'Microsoft.Resources/deployments/operations/read',
      'Microsoft.Resources/deployments/operationstatuses/read',
      'Microsoft.Resources/subscriptions/read',
      'Microsoft.Resources/subscriptions/resourceGroups/read',
      'Microsoft.Resources/subscriptions/operationresults/read'
  )
  Set-RoleAssignment -Role $deploymentRoleName -Scope $subscriptionScope -AllowReplicationRetry

  # 5. Per resource group: deploy resources, and assign only the listed data-plane roles.
  $roleList = ($DelegatableRoleDefinitionIds | ForEach-Object { $_.ToLowerInvariant() }) -join ', '
  $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))"

  if ($GrantLockManagement) {
      $lockRoleName = 'DefenStack Resource Lock Operator'
      Set-CustomRole -Name $lockRoleName -Description 'Create, read, and delete management locks for DefenStack deployments.' -Actions @(
          'Microsoft.Authorization/locks/read',
          'Microsoft.Authorization/locks/write',
          'Microsoft.Authorization/locks/delete'
      )
  }

  foreach ($resourceGroupScope in $resourceGroupScopes) {
      Set-RoleAssignment -Role 'Contributor' -Scope $resourceGroupScope
      Set-RoleAssignment -Role 'Role Based Access Control Administrator' -Scope $resourceGroupScope -Condition $condition
      if ($GrantLockManagement) {
          Set-RoleAssignment -Role $lockRoleName -Scope $resourceGroupScope -AllowReplicationRetry
      }
  }

  $result = [pscustomobject]@{
      AZURE_CLIENT_ID       = $appId
      AZURE_TENANT_ID       = $tenantId
      AZURE_SUBSCRIPTION_ID = $SubscriptionId
  }

  Write-Host ''
  Write-Host "Create these variables on both GitHub environments '$($credentialEnvironments -join "' and '")' (Settings > Environments), or run:"
  foreach ($credentialEnvironment in $credentialEnvironments) {
      foreach ($property in $result.PSObject.Properties) {
          Write-Host "gh variable set $($property.Name) --env $credentialEnvironment --repo $GitHubRepository --body '$($property.Value)'"
      }
  }

  $result
  ```

- [ ] **Step 7: Build, lint, test, PSRule**

  ```bash
  bicep build main.bicep
  for f in main.bicep modules/*.bicep; do bicep lint "$f" || echo "LINT FAIL $f"; done
  ```

  Expected: no `LINT FAIL`. Then run the full suite: `Tests Passed: 345, Failed: 0`. Then run PSRule: 0 failures, 808 results. The dev LRS account is suppressed by `DefenStack.DevLocallyRedundantStorage`.

- [ ] **Step 8: Commit**

  ```bash
  git add modules/storageSecondaryEndpoint.bicep modules/storageReaderAssignment.bicep modules/regionStamp.bicep main.bicep main.json ps-rule.yaml .ps-rule/Suppression.Rule.yaml scripts/New-GitHubDeploymentIdentity.ps1 tests/StorageResilience.Tests.ps1 tests/RegionStamp.Tests.ps1 tests/Scripts.Tests.ps1
  git commit -m "feat: RA-GZRS for prod primary storage with a read-only warm-standby path to the geo-replica" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 2: One Application Insights component per region, Entra ID ingestion, App Service default-deny

**Files:**
- Create: `modules/appInsights.bicep`, `modules/appInsightsPublisher.bicep`, `tests/AppInsights.Tests.ps1`
- Replace: `modules/appService.bicep`, `modules/regionStamp.bicep`, `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Scripts.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes (Task 1):** stamp output `appServicePrincipalId`, the `names` variable, and the `appService` module output `appServicePrincipalId`.
- **Produces:**
  - `appInsights.bicep(location, componentName, logAnalyticsWorkspaceId)`, with outputs `id`, `name` and `connectionString`.
  - `appInsightsPublisher.bicep(componentName, publisherPrincipalId, publisherAppServiceName)`.
  - `appService.bicep` param `applicationInsightsConnectionString = ''` and variable `telemetrySettings`.
  - Stamp `names.appInsights`, module deployments `app-insights` and `app-insights-publisher`, and output `appInsightsName`.
  - The delegatable roles gain `3913510d-42f4-4e42-8a64-420c390055eb`.

- [ ] **Step 1: Write the failing tests**

  Create `tests/AppInsights.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $componentTemplate = Get-BicepTemplate -RelativePath 'modules/appInsights.bicep'
      $component = Get-TemplateResource -Template $componentTemplate -Type 'Microsoft.Insights/components' | Select-Object -First 1
      $publisherTemplate = Get-BicepTemplate -RelativePath 'modules/appInsightsPublisher.bicep'
      $publisher = Get-TemplateResource -Template $publisherTemplate -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
      $appServiceTemplate = Get-BicepTemplate -RelativePath 'modules/appService.bicep'
      $site = Get-TemplateResource -Template $appServiceTemplate -Type 'Microsoft.Web/sites' | Select-Object -First 1
      $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
  }

  Describe 'Application Insights component (Phase 5)' {
      It 'is workspace-based, storing telemetry in the central workspace' {
          $component.kind | Should -Be 'web'
          $component.properties.WorkspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
          $component.properties.IngestionMode | Should -Be 'LogAnalytics'
      }

      It 'accepts only Entra ID-authenticated telemetry (no instrumentation-key ingestion)' {
          $component.properties.DisableLocalAuth | Should -BeExactly $true
      }

      It 'keeps public ingestion and query until Phase 6 adds AMPLS' {
          $component.properties.publicNetworkAccessForIngestion | Should -Be 'Enabled'
          $component.properties.publicNetworkAccessForQuery | Should -Be 'Enabled'
      }

      It 'outputs the connection string the App Service needs' {
          $componentTemplate.outputs.connectionString.value | Should -Match 'ConnectionString'
      }
  }

  Describe 'Telemetry publisher role (Phase 5)' {
      It 'grants Monitoring Metrics Publisher on the component only' {
          $publisherTemplate.variables.monitoringMetricsPublisherRoleId | Should -Be '3913510d-42f4-4e42-8a64-420c390055eb'
          $publisher.scope | Should -Be "[resourceId('Microsoft.Insights/components', parameters('componentName'))]"
          $publisher.properties.principalType | Should -Be 'ServicePrincipal'
          $publisher.properties.principalId | Should -Be "[parameters('publisherPrincipalId')]"
      }
  }

  Describe 'App Service telemetry and hardening (Phase 5)' {
      It 'sends telemetry with the connection string and Entra ID authentication only when a component is given' {
          $appServiceTemplate.parameters.applicationInsightsConnectionString.defaultValue | Should -Be ''
          $appServiceTemplate.variables.telemetrySettings | Should -Match "^\[if\(empty\(parameters\('applicationInsightsConnectionString'\)\), createArray\(\)"
          $appServiceTemplate.variables.telemetrySettings | Should -Match "'APPLICATIONINSIGHTS_CONNECTION_STRING'"
          $appServiceTemplate.variables.telemetrySettings | Should -Match "'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', 'value', 'Authorization=AAD'"
          $site.properties.siteConfig.appSettings | Should -Be "[variables('telemetrySettings')]"
      }

      It 'denies all public access to the site and Kudu by default even if public access is re-enabled' {
          $site.properties.siteConfig.ipSecurityRestrictionsDefaultAction | Should -Be 'Deny'
          $site.properties.siteConfig.scmIpSecurityRestrictionsDefaultAction | Should -Be 'Deny'
          $site.properties.publicNetworkAccess | Should -Be 'Disabled'
      }
  }

  Describe 'Region stamp telemetry wiring (Phase 5)' {
      It 'creates one component per region, named with environment and region' {
          $stamp.variables.names.appInsights | Should -Be "[format('appi-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
          (Get-ModuleDeployment -Template $stamp -Name 'app-insights').properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
      }

      It 'passes the regional connection string to the App Service' {
          (Get-ModuleDeployment -Template $stamp -Name 'app-service').properties.parameters.applicationInsightsConnectionString.value |
              Should -Be "[reference('appInsights').outputs.connectionString.value]"
      }

      It 'grants the App Service identity the publisher role on its own component' {
          $parameters = (Get-ModuleDeployment -Template $stamp -Name 'app-insights-publisher').properties.parameters
          $parameters.publisherPrincipalId.value | Should -Be "[reference('appService').outputs.appServicePrincipalId.value]"
          $parameters.componentName.value | Should -Be "[reference('appInsights').outputs.name.value]"
      }
  }
  ```

  Replace `tests/Scripts.Tests.ps1` (Task 1's version, with the ABAC condition now including `3913510d-...`):

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $scriptPath = Get-RepoPath 'scripts/New-GitHubDeploymentIdentity.ps1'
      $resourceGroups = @('rg-defenstack-dev-global', 'rg-defenstack-dev-wus3')

      # Shadows the Azure CLI for one test. $Responses maps a -like pattern (matched against the joined
      # arguments, first match wins) to the value to return; every call is recorded in $global:AzCalls.
      function Set-AzShadow([System.Collections.Specialized.OrderedDictionary]$Responses) {
          $global:AzCalls = [System.Collections.Generic.List[string]]::new()
          $global:FederatedCredentialPayloads = [System.Collections.Generic.List[string]]::new()
          $global:AzResponses = $Responses
          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              $global:LASTEXITCODE = 0
              if ($joined -like 'role definition create*') {
                  $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                  $global:RoleDefinitionPayload = Get-Content $file -Raw
              }
              if ($joined -like 'ad app federated-credential create*') {
                  $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                  $global:FederatedCredentialPayloads.Add((Get-Content $file -Raw))
              }
              foreach ($pattern in $global:AzResponses.Keys) {
                  if ($joined -like $pattern) { return $global:AzResponses[$pattern] }
              }
              return ''
          }
      }

      function Remove-AzShadow {
          Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
          Remove-Variable -Name AzResponses -Scope Global -ErrorAction SilentlyContinue
      }

      function New-BaseResponses {
          $responses = [ordered]@{}
          $responses['account show*tenantId*'] = '11111111-1111-1111-1111-111111111111'
          $responses['account show*'] = '22222222-2222-2222-2222-222222222222'
          $responses
      }
  }

  Describe 'New-GitHubDeploymentIdentity.ps1' {
      It 'exists and parses without errors' {
          $scriptPath | Should -Exist
          $tokens = $null
          $errors = $null
          [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
          $errors | Should -BeNullOrEmpty
      }

      It 'supports -WhatIf' {
          (Get-Command $scriptPath).Parameters.Keys | Should -Contain 'WhatIf'
      }

      It 'makes no Azure or Entra changes under -WhatIf' {
          Set-AzShadow (New-BaseResponses)
          try {
              & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
          }
          finally {
              Remove-AzShadow
          }
          $mutations = $global:AzCalls | Where-Object { $_ -match '\b(create|delete|update|reset|add|remove)\b' }
          $mutations | Should -BeNullOrEmpty
      }

      It 'rejects delegating privileged role <_>' -ForEach @(
          '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
          '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
          'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
          'b24988ac-6180-42a0-ab88-20f7382dd24c'
      ) {
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds $_ -WhatIf } |
                  Should -Throw -ExpectedMessage '*privileged*'
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'rejects a delegatable role ID that is not a GUID' {
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds 'Owner' -WhatIf } |
                  Should -Throw
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses to proceed when multiple applications share the display name' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = @('aaaaaaaa-1111-1111-1111-111111111111', 'bbbbbbbb-2222-2222-2222-222222222222')
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage '*Multiple Entra applications*'
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses an existing federated credential with a different subject' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
          $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
          $responses['*federated-credential list*'] = 'repo:someone-else/bicep:environment:dev'
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses an existing unconditioned RBAC Administrator assignment' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
          $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
          $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
          $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
          $responses['*role definition list*'] = 'existing-custom-role'
          $responses['*role assignment list*condition*'] = ''
          $responses['*role assignment list*'] = 'eeeeeeee-5555-5555-5555-555555555555'
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage '*unconditioned*'
          }
          finally {
              Remove-AzShadow
          }
      }

      Context 'when creating assignments (non-WhatIf run against the shadow)' {
          BeforeAll {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
              $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $creates = @($global:AzCalls | Where-Object { $_ -like 'role assignment create*' })
          }

          It 'assigns the subscription deployment role at subscription scope only' {
              $deploymentAssignments = @($creates | Where-Object { $_ -like "*--role DefenStack Subscription Deployment Operator*" })
              $deploymentAssignments.Count | Should -Be 1
              $deploymentAssignments[0] | Should -BeLike '*--scope /subscriptions/22222222-2222-2222-2222-222222222222 *'
          }

          It 'assigns Contributor and constrained RBAC Administrator on each resource group, never at subscription scope' {
              foreach ($resourceGroup in $resourceGroups) {
                  $scope = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/$resourceGroup"
                  @($creates | Where-Object { $_ -like "*--role Contributor --scope $scope *" }).Count | Should -Be 1
                  @($creates | Where-Object { $_ -like "*--role Role Based Access Control Administrator --scope $scope *" }).Count | Should -Be 1
              }
              @($creates | Where-Object { $_ -like '*--role Contributor --scope /subscriptions/22222222-2222-2222-2222-222222222222 *' }).Count | Should -Be 0
          }

          It 'constrains RBAC Administrator with the exact ABAC condition for the delegatable roles (Storage Blob Data Contributor, Virtual Machine Administrator Login, Storage Blob Data Reader, Monitoring Metrics Publisher)' {
              $expected = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb}))"
              $rbacAdmin = @($creates | Where-Object { $_ -like '*--role Role Based Access Control Administrator*' })
              $rbacAdmin.Count | Should -Be 2
              foreach ($call in $rbacAdmin) {
                  # Literal match: the condition contains [ and ], which -like would treat as wildcards.
                  $call.Contains("--condition $expected --condition-version 2.0") | Should -BeTrue -Because $call
              }
          }
      }

      Context 'when creating the subscription deployment role (role definition missing)' {
          BeforeAll {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
              $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
              $responses['*role definition list*'] = ''
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $script:roleDefinitionPayload = $global:RoleDefinitionPayload | ConvertFrom-Json
          }

          It 'grants exactly the 9 deployment-operation and read-only actions, no wildcard' {
              $expectedActions = @(
                  'Microsoft.Resources/deployments/read',
                  'Microsoft.Resources/deployments/write',
                  'Microsoft.Resources/deployments/validate/action',
                  'Microsoft.Resources/deployments/whatIf/action',
                  'Microsoft.Resources/deployments/operations/read',
                  'Microsoft.Resources/deployments/operationstatuses/read',
                  'Microsoft.Resources/subscriptions/read',
                  'Microsoft.Resources/subscriptions/resourceGroups/read',
                  'Microsoft.Resources/subscriptions/operationresults/read'
              )
              @($script:roleDefinitionPayload.Actions | Sort-Object) | Should -Be @($expectedActions | Sort-Object)
              $script:roleDefinitionPayload.Actions | Should -Not -Contain '*'
          }

          It 'is assignable only at the subscription scope' {
              @($script:roleDefinitionPayload.AssignableScopes) | Should -Be @('/subscriptions/22222222-2222-2222-2222-222222222222')
          }
      }

      Context 'federated credentials for the plan and apply environments (Phase 2)' {
          It 'creates github-<env> and github-<env>-plan with their exact environment subjects' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 2
              ($credentials | Where-Object { $_.name -eq 'github-dev' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev'
              ($credentials | Where-Object { $_.name -eq 'github-dev-plan' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev-plan'
              foreach ($credential in $credentials) {
                  $credential.issuer | Should -BeExactly 'https://token.actions.githubusercontent.com'
                  @($credential.audiences) | Should -Be @('api://AzureADTokenExchange')
              }
          }

          It 'creates only github-staging for an environment not on the ungated-plan allowlist, with no plan credential (Final review D.7, fail closed)' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'staging' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-staging'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:staging'
          }

          It 'creates only github-prod for the prod environment, with no plan credential' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'prod' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-prod'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:prod'
          }

          It 'refuses an existing credential whose subject differs only in case' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*'] = 'repo:godson90/bicep:environment:dev'
              Set-AzShadow $responses
              try {
                  { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                      Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
              }
              finally {
                  Remove-AzShadow
              }
          }
      }
  }

  AfterAll {
      Remove-Variable -Name AzCalls, FederatedCredentialPayloads, RoleDefinitionPayload -Scope Global -ErrorAction SilentlyContinue
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected failures: `bicep build failed for modules/appInsights.bicep`, the App Service telemetry and default-deny tests, and the ABAC condition test.

- [ ] **Step 3: Create the modules**

  Create `modules/appInsights.bicep`:

  ```bicep
  @description('Azure region for the Application Insights component (the stamp region).')
  param location string

  @description('Application Insights component name.')
  @minLength(1)
  @maxLength(260)
  param componentName string

  @description('Central Log Analytics workspace resource ID; telemetry is stored there (workspace-based).')
  param logAnalyticsWorkspaceId string

  // Workspace-based, Entra ID-only ingestion: the App Service identity needs Monitoring Metrics Publisher (appInsightsPublisher.bicep).
  // Public ingestion and query stay enabled until Phase 6 adds the Azure Monitor Private Link Scope (AMPLS).
  resource component 'Microsoft.Insights/components@2020-02-02' = {
    name: componentName
    location: location
    kind: 'web'
    properties: {
      Application_Type: 'web'
      WorkspaceResourceId: logAnalyticsWorkspaceId
      IngestionMode: 'LogAnalytics'
      DisableLocalAuth: true
      publicNetworkAccessForIngestion: 'Enabled'
      publicNetworkAccessForQuery: 'Enabled'
    }
  }

  output id string = component.id
  output name string = component.name
  output connectionString string = component.properties.ConnectionString
  ```

  Create `modules/appInsightsPublisher.bicep`:

  ```bicep
  // Lets an App Service identity send telemetry to a component whose local (key-based) authentication is disabled.

  @description('Application Insights component name in this resource group.')
  @minLength(1)
  @maxLength(260)
  param componentName string

  @description('Principal ID of the App Service managed identity that publishes telemetry.')
  param publisherPrincipalId string

  @description('Name of the App Service that owns the identity, used to make the assignment GUID deterministic.')
  @minLength(2)
  @maxLength(60)
  param publisherAppServiceName string

  var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

  resource component 'Microsoft.Insights/components@2020-02-02' existing = {
    name: componentName
  }

  resource publisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: guid(component.id, publisherAppServiceName, monitoringMetricsPublisherRoleId)
    scope: component
    properties: {
      principalId: publisherPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    }
  }
  ```

- [ ] **Step 4: Update the App Service, the stamp and the identity defaults**

  Replace `modules/appService.bicep`:

  ```bicep
  @description('Azure region for the App Service plan and application.')
  param location string

  @description('Globally unique App Service application name.')
  @minLength(2)
  @maxLength(60)
  param appServiceAppName string

  @description('Delegated subnet resource ID used for App Service regional VNet integration.')
  param vnetIntegrationSubnetId string = ''

  @description('Log Analytics workspace resource ID for App Service diagnostics.')
  param logAnalyticsWorkspaceId string

  @allowed(
    [
      'prod'
      'dev'
      'test'
    ]
  )

  @description('Deployment environment that controls App Service plan sizing.')
  param environmentType string

  @description('Relative path probed by App Service health check; it must return 200-299 when the instance is healthy.')
  param healthCheckPath string = '/'

  @description('Spread plan instances across availability zones. Zone redundancy is set when a plan is created, so enable it only for new plans.')
  param zoneRedundant bool = false

  @description('Number of plan instances. Zone-redundant plans require at least 3.')
  @minValue(1)
  @maxValue(30)
  param instanceCount int = 1

  @description('Application Insights connection string for this region. Empty sends no telemetry.')
  param applicationInsightsConnectionString string = ''

  @description('App Service plan name. Include the environment and region so every stamp gets its own plan.')
  @minLength(1)
  @maxLength(60)
  param appServicePlanName string

  var appServicePlanSkuName = (environmentType == 'prod') ? 'P2V3' : 'S1'
  var appServicePlanSkuTier = (environmentType == 'prod') ? 'PremiumV3' : 'Standard'
  // Entra ID (managed identity) telemetry authentication; the component disables key-based ingestion.
  var telemetrySettings = empty(applicationInsightsConnectionString) ? [] : [
    {
      name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
      value: applicationInsightsConnectionString
    }
    {
      name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
      value: 'Authorization=AAD'
    }
  ]

  // App service plan creation
  // Environment-specific plan capacity for the private, VNet-integrated application.
  resource appServiceplan 'Microsoft.Web/serverfarms@2025-03-01' = {
    name: appServicePlanName
    location: location
    sku: {
      name: appServicePlanSkuName
      tier: appServicePlanSkuTier
      capacity: instanceCount
    }
    properties: {
      zoneRedundant: zoneRedundant
    }
  }

  // App service app creation
  // Private App Service with managed identity, HTTPS-only access, and route-all enabled.
  resource appServiceApp 'Microsoft.Web/sites@2025-03-01' = {
    name: appServiceAppName
    location: location
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      serverFarmId: appServiceplan.id
      httpsOnly: true
      publicNetworkAccess: 'Disabled'
      clientAffinityEnabled: false
      virtualNetworkSubnetId: empty(vnetIntegrationSubnetId) ? null : vnetIntegrationSubnetId
      siteConfig: {
        ftpsState: 'Disabled'
        http20Enabled: true
        minTlsVersion: '1.2'
        vnetRouteAllEnabled: true
        alwaysOn: true
        healthCheckPath: healthCheckPath
        scmMinTlsVersion: '1.2'
        remoteDebuggingEnabled: false
        // Public access is disabled; default-deny keeps the site and Kudu closed even if it is ever re-enabled.
        ipSecurityRestrictionsDefaultAction: 'Deny'
        scmIpSecurityRestrictionsDefaultAction: 'Deny'
        appSettings: telemetrySettings
      }
    }
  }

  // Basic (username/password) publishing is disabled; deployments use Entra ID tokens.
  resource ftpBasicPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
    parent: appServiceApp
    name: 'ftp'
    properties: {
      allow: false
    }
  }

  resource scmBasicPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
    parent: appServiceApp
    name: 'scm'
    properties: {
      allow: false
    }
  }

  // Application platform and request telemetry are sent to the central workspace.
  resource appServiceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: appServiceApp
    name: 'appservice-diagnostics'
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logs: [
        {
          categoryGroup: 'allLogs'
          enabled: true
        }
      ]
      metrics: [
        {
          category: 'AllMetrics'
          enabled: true
        }
      ]
    }
  }

  output appServiceAppHostName string = appServiceApp.properties.defaultHostName
  output appServiceAppId string = appServiceApp.id
  output appServicePrincipalId string = appServiceApp.identity.principalId
  ```

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet } from 'types.bicep'

  @description('Deployment environment.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Role of this region in the active/passive design. Only the primary gets zone-redundant App Service capacity and the optional management VM.')
  @allowed([
    'primary'
    'secondary'
  ])
  param regionRole string

  @description('Azure region for this stamp.')
  param location string

  @description('Short lowercase region code used in resource names, for example wus3 or eus.')
  @minLength(2)
  @maxLength(4)
  param regionCode string

  @description('Hub and spoke address plan for this region.')
  param addressPlan regionAddressPlan

  @description('Central Log Analytics workspace resource ID from the global layer.')
  param logAnalyticsWorkspaceId string

  @description('Shared private DNS zone resource IDs from the global layer.')
  param privateDnsZoneIds privateDnsZoneSet

  @description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('Relative path probed by App Service health check.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM (primary region only).')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in this region. The warm standby leaves it off until failover.')
  param deployAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  var isProd = environmentName == 'prod'
  var isPrimary = regionRole == 'primary'
  var nameSuffix = uniqueString(subscription().id, environmentName, location)
  var availabilityZones = [
    '1'
    '2'
    '3'
  ]
  var names = {
    hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
    spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
    firewall: 'afw-defenstack-${environmentName}-${regionCode}'
    firewallPolicy: 'afwp-defenstack-${environmentName}-${regionCode}'
    firewallPublicIp: 'pip-afw-defenstack-${environmentName}-${regionCode}'
    storageAccount: 'st${regionCode}${nameSuffix}'
    keyVault: 'kv-${regionCode}-${nameSuffix}'
    appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
    appService: 'app-defenstack-${environmentName}-${regionCode}-${take(nameSuffix, 6)}'
    virtualMachine: 'vm${regionCode}${take(nameSuffix, 7)}'
    bastion: 'bas-defenstack-${environmentName}-${regionCode}'
    bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
    vpnGateway: 'vpng-defenstack-${environmentName}-${regionCode}'
    vpnGatewayPublicIp: 'pip-vpng-defenstack-${environmentName}-${regionCode}'
    appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module keyVault 'keyVault.bicep' = {
    name: 'key-vault'
    params: {
      location: location
      keyVaultName: names.keyVault
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      enablePurgeProtection: true
      enabledForTemplateDeployment: true
      enableDeleteLock: isProd
    }
  }

  module hubNetwork 'hubNetwork.bicep' = {
    name: 'hub-network'
    params: {
      location: location
      vnetName: names.hubVnet
      addressSpace: addressPlan.hubAddressSpace
      firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
      bastionSubnetAddressPrefix: addressPlan.bastionSubnetPrefix
      gatewaySubnetAddressPrefix: addressPlan.gatewaySubnetPrefix
      firewallPrivateIp: firewallPrivateIp
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      bastionTargetAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      enableDeleteLock: isProd
    }
  }

  module azureFirewall 'azureFirewall.bicep' = {
    name: 'azure-firewall'
    params: {
      location: location
      firewallName: names.firewall
      firewallPolicyName: names.firewallPolicy
      publicIpName: names.firewallPublicIp
      firewallSubnetId: hubNetwork.outputs.firewallSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      managementAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      vpnClientAddressPrefixes: [
        addressPlan.vpnClientAddressPool
      ]
      allowedOutboundFqdns: allowedOutboundFqdns
      threatIntelMode: isProd ? 'Deny' : 'Alert'
      availabilityZones: availabilityZones
      firewallTier: 'Premium'
      idpsMode: isProd ? 'Deny' : 'Alert'
      enableDeleteLock: isProd
    }
  }

  module spokeNetwork 'spokeNetwork.bicep' = {
    name: 'spoke-network'
    params: {
      location: location
      vnetName: names.spokeVnet
      firewallPrivateIp: azureFirewall.outputs.privateIp
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      vnetAddressSpace: addressPlan.spokeAddressSpace
      privateEndpointSubnetAddressPrefix: addressPlan.privateEndpointSubnetPrefix
      appServiceIntegrationSubnetAddressPrefix: addressPlan.appServiceIntegrationSubnetPrefix
      virtualMachineSubnetAddressPrefix: addressPlan.managementSubnetPrefix
      approvedPrivateEndpointSourceCidrs: concat([
        addressPlan.appServiceIntegrationSubnetPrefix
        addressPlan.managementSubnetPrefix
        addressPlan.vpnClientAddressPool
      ], additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  // One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
  module appInsights 'appInsights.bicep' = {
    name: 'app-insights'
    params: {
      location: location
      componentName: names.appInsights
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module appService 'appService.bicep' = {
    name: 'app-service'
    params: {
      location: location
      appServiceAppName: names.appService
      appServicePlanName: names.appServicePlan
      environmentType: environmentName
      vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      healthCheckPath: healthCheckPath
      zoneRedundant: isProd && isPrimary
      instanceCount: isProd && isPrimary ? 3 : 1
      applicationInsightsConnectionString: appInsights.outputs.connectionString
    }
  }

  module appInsightsPublisher 'appInsightsPublisher.bicep' = {
    name: 'app-insights-publisher'
    params: {
      componentName: appInsights.outputs.name
      publisherPrincipalId: appService.outputs.appServicePrincipalId
      publisherAppServiceName: names.appService
    }
  }

  module virtualMachine 'virtualMachine.bicep' = if (enableVirtualMachine && isPrimary) {
    name: 'virtual-machine'
    params: {
      location: location
      vmName: names.virtualMachine
      osType: virtualMachineOsType
      subnetId: spokeNetwork.outputs.virtualMachineSubnetId
      adminUsername: virtualMachineAdminUsername
      adminSshPublicKey: virtualMachineAdminSshPublicKey
      adminPassword: virtualMachineAdminPassword
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      managementSourceCidrs: adminSourceCidrs
      adminGroupObjectId: adminGroupObjectId
    }
  }

  module bastion 'bastion.bicep' = if (deployAdminAccess) {
    name: 'bastion'
    params: {
      location: location
      bastionName: names.bastion
      publicIpName: names.bastionPublicIp
      subnetId: hubNetwork.outputs.bastionSubnetId
      availabilityZones: availabilityZones
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    // The hub resolves DNS through the firewall, so admin access waits for it.
    dependsOn: [
      azureFirewall
    ]
  }

  module vpnGateway 'vpnGateway.bicep' = if (deployAdminAccess) {
    name: 'vpn-gateway'
    params: {
      location: location
      gatewayName: names.vpnGateway
      publicIpNamePrefix: names.vpnGatewayPublicIp
      gatewaySubnetId: hubNetwork.outputs.gatewaySubnetId
      skuName: isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'
      availabilityZones: availabilityZones
      vpnClientAddressPool: addressPlan.vpnClientAddressPool
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    dependsOn: [
      azureFirewall
    ]
  }

  module networkIntegration 'networkIntegration.bicep' = {
    name: 'network-integration'
    params: {
      hubVnetName: names.hubVnet
      hubVnetId: hubNetwork.outputs.id
      spokeVnetName: names.spokeVnet
      spokeVnetId: spokeNetwork.outputs.id
      storageAccountName: names.storageAccount
      storageAccountId: storage.outputs.id
      storageContainerName: storage.outputs.blobContainerName
      appServicePrincipalId: appService.outputs.appServicePrincipalId
      appServiceName: names.appService
      useHubGateway: deployAdminAccess
    }
    // Gateway transit on the peering needs a provisioned gateway.
    dependsOn: [
      vpnGateway
    ]
  }

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
    }
  }

  module privateConnectivity 'privateConnectivity.bicep' = {
    name: 'private-connectivity'
    params: {
      location: location
      storageAccountId: storage.outputs.id
      storageAccountName: names.storageAccount
      appServiceId: appService.outputs.appServiceAppId
      appServiceName: names.appService
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      keyVaultId: keyVault.outputs.id
      keyVaultName: names.keyVault
      privateDnsZoneIds: privateDnsZoneIds
    }
  }

  output hubVnetName string = names.hubVnet
  output hubVnetId string = hubNetwork.outputs.id
  output spokeVnetName string = names.spokeVnet
  output spokeVnetId string = spokeNetwork.outputs.id
  output firewallPrivateIp string = azureFirewall.outputs.privateIp
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceId string = appService.outputs.appServiceAppId
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  output appInsightsName string = appInsights.outputs.name
  ```

  Replace `scripts/New-GitHubDeploymentIdentity.ps1`:

  ```powershell
  [CmdletBinding(SupportsShouldProcess)]
  param(
      [Parameter(Mandatory)]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^[-\w._()]{1,90}$')]
      [string[]]$ResourceGroupNames,

      [Parameter(Mandatory)]
      [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
      [string]$GitHubRepository,

      [Parameter(Mandatory)]
      [ValidatePattern('^[A-Za-z0-9_-]+$')]
      [string]$EnvironmentName,

      [Parameter()]
      [string]$SubscriptionId,

      [Parameter()]
      [ValidatePattern('^[A-Za-z0-9._-]{1,120}$')]
      [string]$DisplayName,

      [Parameter()]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
      [ValidateScript({
              # Owner, User Access Administrator, RBAC Administrator, Contributor: never delegable.
              $privileged = @(
                  '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
                  '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
                  'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
                  'b24988ac-6180-42a0-ab88-20f7382dd24c'
              )
              if ($privileged -contains $_.ToLowerInvariant()) { throw "Role definition $_ is privileged and cannot be delegated to the pipeline." }
              $true
          })]
      [string[]]$DelegatableRoleDefinitionIds = @(
          'ba92f5b4-2d11-453d-a403-e96b0029c9fe', # Storage Blob Data Contributor (app identity, container scope)
          '1c0163c0-47e6-4577-8991-ea5c82e286e4', # Virtual Machine Administrator Login (admin group, jump host; Phase 3)
          '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1', # Storage Blob Data Reader (warm-standby app on the primary container; Phase 5)
          '3913510d-42f4-4e42-8a64-420c390055eb'  # Monitoring Metrics Publisher (App Service identity on its App Insights component; Phase 5)
      ),

      [Parameter()]
      [switch]$GrantLockManagement,

      [Parameter()]
      [ValidateRange(0, 600)]
      [int]$RoleReplicationWaitSeconds = 20
  )

  $ErrorActionPreference = 'Stop'

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
      throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
  }

  if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
      $SubscriptionId = az account show --query id --output tsv
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
          throw 'No active Azure subscription was found. Run az login or provide -SubscriptionId.'
      }
  }

  $tenantId = az account show --subscription $SubscriptionId --query tenantId --output tsv
  if ($LASTEXITCODE -ne 0) {
      throw 'Unable to read the tenant ID for the subscription.'
  }

  if ([string]::IsNullOrWhiteSpace($DisplayName)) {
      $DisplayName = "gh-$($GitHubRepository.Replace('/', '-'))-$EnvironmentName-deploy"
  }

  $subscriptionScope = "/subscriptions/$SubscriptionId"
  $resourceGroupScopes = @($ResourceGroupNames | ForEach-Object { "$subscriptionScope/resourceGroups/$_" })
  # The deploy workflow's plan job runs in '<env>-plan' (no reviewers) only for the environments listed here;
  # every other environment's plan job runs in the gated '<env>' environment alongside apply, so it gets no
  # ungated '-plan' credential. Fail closed: an environment must be explicitly opted in to get an ungated plan
  # credential. Today only dev is opted in; prod (ADR-012) and any future environment (for example a 'staging')
  # get no '-plan' credential unless deliberately added here.
  $ungatedPlanEnvironments = @('dev')
  $credentialEnvironments = if ($ungatedPlanEnvironments -contains $EnvironmentName) { @($EnvironmentName, "$EnvironmentName-plan") } else { @($EnvironmentName) }

  Write-Host "Application: $DisplayName"
  Write-Host "Federated subjects: $(($credentialEnvironments | ForEach-Object { "repo:${GitHubRepository}:environment:$_" }) -join ', ')"
  Write-Host "Resource group scopes: $($resourceGroupScopes -join ', ')"

  # 1. Application registration (idempotent by exact display name match).
  $appMatches = @(az ad app list --display-name $DisplayName --query "[?displayName=='$DisplayName'].appId" --output tsv | Where-Object { $_ })
  if ($LASTEXITCODE -ne 0) {
      throw "Failed to query Entra applications named '$DisplayName'."
  }
  if ($appMatches.Count -gt 1) {
      throw "Multiple Entra applications are named '$DisplayName'. Resolve the duplicates or pass a unique -DisplayName."
  }
  $appId = if ($appMatches.Count -eq 1) { $appMatches[0] } else { $null }
  if ([string]::IsNullOrWhiteSpace($appId)) {
      if ($PSCmdlet.ShouldProcess($DisplayName, 'Create Entra application registration')) {
          $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId --output tsv
          if ($LASTEXITCODE -ne 0) { throw 'Failed to create the application registration.' }
      }
      else {
          $appId = '<new-application-id>'
      }
  }

  # 2. Service principal.
  $servicePrincipalId = $null
  if ($appId -ne '<new-application-id>') {
      $servicePrincipalId = az ad sp list --filter "appId eq '$appId'" --query '[0].id' --output tsv
  }
  if ([string]::IsNullOrWhiteSpace($servicePrincipalId)) {
      if ($PSCmdlet.ShouldProcess($appId, 'Create service principal')) {
          $servicePrincipalId = az ad sp create --id $appId --query id --output tsv
          if ($LASTEXITCODE -ne 0) { throw 'Failed to create the service principal.' }
      }
      else {
          $servicePrincipalId = '<new-service-principal-object-id>'
      }
  }

  # 3. Federated credentials bound to the GitHub environments; an existing one must have exactly the same subject.
  function Set-FederatedCredential {
      param(
          [string]$GitHubEnvironment
      )

      $credentialName = "github-$GitHubEnvironment"
      $subject = "repo:${GitHubRepository}:environment:$GitHubEnvironment"

      $existingSubject = $null
      if ($appId -ne '<new-application-id>') {
          $existingSubject = az ad app federated-credential list --id $appId --query "[?name=='$credentialName'].subject" --output tsv
      }
      if (-not [string]::IsNullOrWhiteSpace($existingSubject)) {
          # Entra matches subjects case-sensitively, so compare case-sensitively too.
          if ($existingSubject -cne $subject) {
              throw "Federated credential '$credentialName' exists with subject '$existingSubject', expected '$subject'. Delete it (az ad app federated-credential delete --id $appId --federated-credential-id $credentialName) and re-run."
          }
          Write-Host "Federated credential '$credentialName' already present."
          return
      }

      if ($PSCmdlet.ShouldProcess($subject, 'Create federated credential')) {
          $credentialFile = New-TemporaryFile
          try {
              @{
                  name        = $credentialName
                  issuer      = 'https://token.actions.githubusercontent.com'
                  subject     = $subject
                  audiences   = @('api://AzureADTokenExchange')
                  description = "GitHub Actions environment '$GitHubEnvironment' for $GitHubRepository"
              } | ConvertTo-Json | Set-Content -Path $credentialFile -Encoding ASCII

              az ad app federated-credential create --id $appId --parameters "@$credentialFile" --output none
              if ($LASTEXITCODE -ne 0) { throw "Failed to create the federated credential '$credentialName'." }
          }
          finally {
              Remove-Item $credentialFile -Force
          }
      }
  }

  foreach ($credentialEnvironment in $credentialEnvironments) {
      Set-FederatedCredential -GitHubEnvironment $credentialEnvironment
  }

  function Set-RoleAssignment {
      param(
          [string]$Role,
          [string]$Scope,
          [string]$Condition,
          [switch]$AllowReplicationRetry
      )

      $existing = $null
      if ($servicePrincipalId -notlike '<*>') {
          $existing = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].id' --output tsv
      }
      if (-not [string]::IsNullOrWhiteSpace($existing)) {
          if ($Condition) {
              $existingCondition = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].condition' --output tsv
              $normalizedExisting = ($existingCondition -replace '\s+', ' ').Trim()
              $normalizedDesired = ($Condition -replace '\s+', ' ').Trim()
              if ([string]::IsNullOrWhiteSpace($normalizedExisting)) {
                  throw "An unconditioned '$Role' assignment already exists at $Scope. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
              }
              if ($normalizedExisting -ne $normalizedDesired) {
                  throw "An existing '$Role' assignment at $Scope has a different condition than expected. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
              }
          }
          Write-Host "Role '$Role' already assigned at $Scope."
          return
      }

      if ($PSCmdlet.ShouldProcess($Scope, "Assign '$Role' to $servicePrincipalId")) {
          $arguments = @(
              'role', 'assignment', 'create',
              '--assignee-object-id', $servicePrincipalId,
              '--assignee-principal-type', 'ServicePrincipal',
              '--role', $Role,
              '--scope', $Scope,
              '--output', 'none'
          )
          if ($Condition) {
              $arguments += @('--condition', $Condition, '--condition-version', '2.0')
          }

          # A just-created custom role can take minutes to replicate before it can be assigned.
          $attempts = if ($AllowReplicationRetry) { 6 } else { 1 }
          for ($attempt = 1; $attempt -le $attempts; $attempt++) {
              az @arguments
              if ($LASTEXITCODE -eq 0) { return }
              if ($attempt -lt $attempts) {
                  Write-Host "Assignment of '$Role' failed (attempt $attempt of $attempts); waiting $RoleReplicationWaitSeconds s for role replication."
                  Start-Sleep -Seconds $RoleReplicationWaitSeconds
              }
          }
          throw "Failed to assign '$Role' at $Scope."
      }
  }

  function Set-CustomRole {
      param(
          [string]$Name,
          [string]$Description,
          [string[]]$Actions
      )

      $existingRole = az role definition list --name $Name --custom-role-only true --query '[0].name' --output tsv
      if (-not [string]::IsNullOrWhiteSpace($existingRole)) { return }

      if ($PSCmdlet.ShouldProcess($Name, 'Create custom role')) {
          $roleFile = New-TemporaryFile
          try {
              @{
                  Name             = $Name
                  Description      = $Description
                  Actions          = $Actions
                  NotActions       = @()
                  AssignableScopes = @($subscriptionScope)
              } | ConvertTo-Json | Set-Content -Path $roleFile -Encoding ASCII

              az role definition create --role-definition "@$roleFile" --output none
              if ($LASTEXITCODE -ne 0) { throw "Failed to create the custom role '$Name'." }
          }
          finally {
              Remove-Item $roleFile -Force
          }
      }
  }

  # 4. Subscription-scope deployments only (no resource rights): the entry point targets the subscription,
  #    while every resource lands in a pre-created resource group granted below.
  $deploymentRoleName = 'DefenStack Subscription Deployment Operator'
  Set-CustomRole -Name $deploymentRoleName -Description 'Run subscription-scope ARM deployments (validate, what-if, create) and read resource groups. Grants no resource permissions and cannot cancel or delete deployments.' -Actions @(
      'Microsoft.Resources/deployments/read',
      'Microsoft.Resources/deployments/write',
      'Microsoft.Resources/deployments/validate/action',
      'Microsoft.Resources/deployments/whatIf/action',
      'Microsoft.Resources/deployments/operations/read',
      'Microsoft.Resources/deployments/operationstatuses/read',
      'Microsoft.Resources/subscriptions/read',
      'Microsoft.Resources/subscriptions/resourceGroups/read',
      'Microsoft.Resources/subscriptions/operationresults/read'
  )
  Set-RoleAssignment -Role $deploymentRoleName -Scope $subscriptionScope -AllowReplicationRetry

  # 5. Per resource group: deploy resources, and assign only the listed data-plane roles.
  $roleList = ($DelegatableRoleDefinitionIds | ForEach-Object { $_.ToLowerInvariant() }) -join ', '
  $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))"

  if ($GrantLockManagement) {
      $lockRoleName = 'DefenStack Resource Lock Operator'
      Set-CustomRole -Name $lockRoleName -Description 'Create, read, and delete management locks for DefenStack deployments.' -Actions @(
          'Microsoft.Authorization/locks/read',
          'Microsoft.Authorization/locks/write',
          'Microsoft.Authorization/locks/delete'
      )
  }

  foreach ($resourceGroupScope in $resourceGroupScopes) {
      Set-RoleAssignment -Role 'Contributor' -Scope $resourceGroupScope
      Set-RoleAssignment -Role 'Role Based Access Control Administrator' -Scope $resourceGroupScope -Condition $condition
      if ($GrantLockManagement) {
          Set-RoleAssignment -Role $lockRoleName -Scope $resourceGroupScope -AllowReplicationRetry
      }
  }

  $result = [pscustomobject]@{
      AZURE_CLIENT_ID       = $appId
      AZURE_TENANT_ID       = $tenantId
      AZURE_SUBSCRIPTION_ID = $SubscriptionId
  }

  Write-Host ''
  Write-Host "Create these variables on both GitHub environments '$($credentialEnvironments -join "' and '")' (Settings > Environments), or run:"
  foreach ($credentialEnvironment in $credentialEnvironments) {
      foreach ($property in $result.PSObject.Properties) {
          Write-Host "gh variable set $($property.Name) --env $credentialEnvironment --repo $GitHubRepository --body '$($property.Value)'"
      }
  }

  $result
  ```

- [ ] **Step 5: Build, lint, test, PSRule**

  Run `bicep build main.bicep` and lint every file (no `LINT FAIL`). The full suite should show `Tests Passed: 357, Failed: 0`. PSRule should show 0 failures out of 871 results.

- [ ] **Step 6: Commit**

  ```bash
  git add modules/appInsights.bicep modules/appInsightsPublisher.bicep modules/appService.bicep modules/regionStamp.bicep main.json scripts/New-GitHubDeploymentIdentity.ps1 tests/AppInsights.Tests.ps1 tests/Scripts.Tests.ps1
  git commit -m "feat: per-region Application Insights with Entra ID ingestion and App Service default-deny" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 3: Deploy-time Key Vault secrets for every region

**Files:**
- Create: `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`, `tests/KeyVaultSecrets.Tests.ps1`
- Replace: `modules/keyVault.bicep`, `modules/regionStamp.bicep`, `main.bicep`, `.github/workflows/deploy.yml`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes:** the stamp module deployment `key-vault`, and the `main.bicep` symbols `primaryStamp` and `secondaryStamp`.
- **Produces:**
  - `keyVault.bicep` param `@secure() secrets object = {}`, written as `Microsoft.KeyVault/vaults/secrets`.
  - Stamp and `main.bicep` param `@secure() keyVaultSecrets object = {}`.
  - `ConvertTo-KeyVaultSecretsParameter.ps1 -Json <string> -OutFile <path>`.
  - The `deploy.yml` steps `Prepare Key Vault secrets` (before `Deploy`) and `Remove the secrets file` (`if: always()`).
  - The `Deploy` step passes `--parameters keyVaultSecrets=@"$RUNNER_TEMP/keyvault-secrets.json"`.

- [ ] **Step 1: Write the failing tests**

  Create `tests/KeyVaultSecrets.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $vault = Get-BicepTemplate -RelativePath 'modules/keyVault.bicep'
      $vaultSecrets = Get-TemplateResource -Template $vault -Type 'Microsoft.KeyVault/vaults/secrets' | Select-Object -First 1
      $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
      $main = Get-BicepTemplate -RelativePath 'main.bicep'
      $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
      $converter = Get-RepoPath 'scripts/ConvertTo-KeyVaultSecretsParameter.ps1'
      $outFile = Join-Path ([IO.Path]::GetTempPath()) "kvs-test-$([guid]::NewGuid()).json"
  }

  AfterAll {
      Remove-Item -Path $outFile -ErrorAction SilentlyContinue
  }

  Describe 'Deploy-time Key Vault secrets (Phase 5, ADR-019)' {
      It 'takes secrets as a secure object, empty by default' {
          $vault.parameters.secrets.type | Should -Be 'secureObject'
          $vault.parameters.secrets.PSObject.Properties.Name | Should -Contain 'defaultValue'
          @($vault.parameters.secrets.defaultValue.PSObject.Properties).Count | Should -Be 0
      }

      It 'writes one vault secret per entry through Azure Resource Manager' {
          $vaultSecrets.copy.count | Should -Be "[length(items(parameters('secrets')))]"
          $vaultSecrets.name | Should -Match "items\(parameters\('secrets'\)\)\[copyIndex\(\)\]\.key"
          $vaultSecrets.properties.value | Should -Match "items\(parameters\('secrets'\)\)\[copyIndex\(\)\]\.value"
      }

      It 'passes the same secrets to the Key Vault of every stamp' {
          $stamp.parameters.keyVaultSecrets.type | Should -Be 'secureObject'
          (Get-ModuleDeployment -Template $stamp -Name 'key-vault').properties.parameters.secrets.value | Should -Be "[parameters('keyVaultSecrets')]"
          $main.parameters.keyVaultSecrets.type | Should -Be 'secureObject'
          foreach ($symbol in 'primaryStamp', 'secondaryStamp') {
              (Get-TemplateResourceBySymbol -Template $main -Symbol $symbol).properties.parameters.keyVaultSecrets.value | Should -Be "[parameters('keyVaultSecrets')]"
          }
      }

      It 'never sets keyVaultSecrets in a committed parameter file' {
          foreach ($file in 'params/dev.bicepparam', 'params/prod.bicepparam') {
              Get-Content (Get-RepoPath $file) -Raw | Should -Not -Match 'keyVaultSecrets'
          }
      }
  }

  Describe 'Pipeline secret handling (Phase 5)' {
      It 'reads KEYVAULT_SECRETS_JSON from the environment secrets, converts it, and passes it to the deployment' {
          $deploy | Should -Match ([regex]::Escape('KEYVAULT_SECRETS_JSON: ${{ secrets.KEYVAULT_SECRETS_JSON }}'))
          $prepare = $deploy.IndexOf('./scripts/ConvertTo-KeyVaultSecretsParameter.ps1')
          $create = $deploy.IndexOf('az deployment sub create')
          $prepare | Should -BeGreaterThan -1
          $create | Should -BeGreaterThan $prepare
          $deploy | Should -Match ([regex]::Escape('--parameters keyVaultSecrets=@"$RUNNER_TEMP/keyvault-secrets.json"'))
      }

      It 'always deletes the secrets file after the deployment' {
          $deploy | Should -Match "- name: Remove the secrets file\s+if: always\(\)\s+run: rm -f `"\`$RUNNER_TEMP/keyvault-secrets.json`""
      }
  }

  Describe 'ConvertTo-KeyVaultSecretsParameter.ps1 (Phase 5)' {
      It 'writes {} for empty or missing input' {
          & $converter -Json '' -OutFile $outFile | Out-Null
          Get-Content $outFile -Raw | Should -Be '{}'
          & $converter -OutFile $outFile | Out-Null
          Get-Content $outFile -Raw | Should -Be '{}'
      }

      It 'writes the validated object and reports names, never values' {
          $output = & $converter -Json '{"api-key":"s3cret-value","db-password":"another"}' -OutFile $outFile
          $written = Get-Content $outFile -Raw | ConvertFrom-Json
          $written.'api-key' | Should -Be 's3cret-value'
          $written.'db-password' | Should -Be 'another'
          ($output -join ' ') | Should -Match 'api-key, db-password'
          ($output -join ' ') | Should -Not -Match 's3cret-value'
      }

      It 'rejects <Case>' -ForEach @(
          @{ Case = 'invalid JSON'; Json = '{not json'; Message = '*not valid JSON*' }
          @{ Case = 'a JSON array'; Json = '["a"]'; Message = '*must be a JSON object*' }
          @{ Case = 'a name with an underscore'; Json = '{"api_key":"x"}'; Message = "*Secret name 'api_key' is invalid*" }
          @{ Case = 'an empty value'; Json = '{"api-key":""}'; Message = "*Secret 'api-key' must have a non-empty string value*" }
          @{ Case = 'a non-string value'; Json = '{"api-key":42}'; Message = "*Secret 'api-key' must have a non-empty string value*" }
      ) {
          { & $converter -Json $Json -OutFile $outFile } | Should -Throw $Message
      }

      It 'never echoes a value in an error message' {
          $message = ''
          try { & $converter -Json '{"bad_name":"do-not-leak"}' -OutFile $outFile } catch { $message = $_.Exception.Message }
          $message | Should -Not -Match 'do-not-leak'
      }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected: the `Deploy-time Key Vault secrets`, `Pipeline secret handling` and converter tests fail (missing parameter, steps and script).

- [ ] **Step 3: Create the converter**

  Create `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`:

  ```powershell
  <#
  .SYNOPSIS
  Validates the KEYVAULT_SECRETS_JSON environment secret and writes it as the keyVaultSecrets deployment parameter.

  .DESCRIPTION
  The deploy pipeline keeps application secrets in the GitHub environment secret KEYVAULT_SECRETS_JSON, a JSON
  object of { "secret-name": "value" }. This script checks the object and writes it to -OutFile, which
  deploy.yml passes as `--parameters keyVaultSecrets=@<file>`. Every regional Key Vault then receives the same
  values through Azure Resource Manager (ADR-019).

  Rules: empty or missing input means no secrets ({}). Names must be 1-127 letters, digits or hyphens (the Key Vault
  rule). Values must be non-empty strings. The script never prints a value; error messages name only the secret.
  #>
  [CmdletBinding()]
  param(
      [Parameter()]
      [AllowEmptyString()]
      [AllowNull()]
      [string]$Json,

      [Parameter(Mandatory)]
      [ValidateNotNullOrEmpty()]
      [string]$OutFile
  )

  $ErrorActionPreference = 'Stop'

  $secrets = [ordered]@{}
  if (-not [string]::IsNullOrWhiteSpace($Json)) {
      try {
          $parsed = $Json | ConvertFrom-Json
      }
      catch {
          throw 'KEYVAULT_SECRETS_JSON is not valid JSON. Expected an object such as {"api-key": "value"}.'
      }
      if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
          throw 'KEYVAULT_SECRETS_JSON must be a JSON object of { "secret-name": "value" }.'
      }
      foreach ($property in $parsed.PSObject.Properties) {
          if ($property.Name -cnotmatch '^[0-9A-Za-z-]{1,127}$') {
              throw "Secret name '$($property.Name)' is invalid: use 1-127 letters, digits or hyphens."
          }
          if ($property.Value -isnot [string] -or [string]::IsNullOrEmpty($property.Value)) {
              throw "Secret '$($property.Name)' must have a non-empty string value."
          }
          $secrets[$property.Name] = $property.Value
      }
  }

  $directory = Split-Path -Parent $OutFile
  if ($directory -and -not (Test-Path $directory)) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  [IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $secrets -Compress), (New-Object Text.UTF8Encoding($false)))
  Write-Output "Prepared $($secrets.Count) Key Vault secret(s): $((@($secrets.Keys) | Sort-Object) -join ', ')"
  ```

- [ ] **Step 4: Write the secrets in every vault**

  Replace `modules/keyVault.bicep`:

  ```bicep
  @description('Azure region for the Key Vault.')
  param location string

  @description('Globally unique Key Vault name. Use only letters, numbers, and hyphens.')
  @minLength(3)
  @maxLength(24)
  param keyVaultName string

  @description('Tenant ID that owns the Key Vault.')
  param tenantId string = tenant().tenantId

  @description('Log Analytics workspace resource ID for Key Vault diagnostics.')
  param logAnalyticsWorkspaceId string

  @description('Number of days soft-deleted objects are retained.')
  @minValue(7)
  @maxValue(90)
  param softDeleteRetentionInDays int = 90

  @description('Enable purge protection. Keep enabled for production workloads.')
  param enablePurgeProtection bool = true

  @description('Allow Azure Resource Manager to retrieve secrets during deployments, required for az.getSecret() in .bicepparam files. Keep false for vaults that never back deployment parameters.')
  param enabledForTemplateDeployment bool = false

  @description('Apply a CanNotDelete lock to the vault (in addition to soft delete and purge protection).')
  param enableDeleteLock bool = false

  @description('Application secrets to write, as { name: value }. Written through Azure Resource Manager, so the deploying identity needs no network path to the private vault (ADR-019). Names: letters, digits and hyphens, at most 127 characters.')
  @secure()
  param secrets object = {}

  // RBAC-based vault with public access disabled; clients use its private endpoint.
  resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
    name: keyVaultName
    location: location
    properties: {
      tenantId: tenantId
      enableRbacAuthorization: true
      enableSoftDelete: true
      softDeleteRetentionInDays: softDeleteRetentionInDays
      enablePurgeProtection: enablePurgeProtection
      enabledForTemplateDeployment: enabledForTemplateDeployment
      publicNetworkAccess: 'Disabled'
      sku: {
        family: 'A'
        name: 'standard'
      }
      networkAcls: {
        bypass: enabledForTemplateDeployment ? 'AzureServices' : 'None'
        defaultAction: 'Deny'
      }
    }
  }

  // The same deploy-time values go to every regional vault, which is how the stamps stay in sync (ADR-019).
  resource vaultSecrets 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = [for secret in items(secrets): {
    parent: keyVault
    name: secret.key
    properties: {
      value: secret.value
      attributes: {
        enabled: true
      }
    }
  }]

  // Key Vault audit events are centralized with the other platform diagnostics.
  resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: keyVault
    name: 'keyvault-diagnostics'
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logs: [
        {
          categoryGroup: 'allLogs'
          enabled: true
        }
      ]
      metrics: [
        {
          category: 'AllMetrics'
          enabled: true
        }
      ]
    }
  }

  resource keyVaultLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: keyVault
    name: '${keyVaultName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  output id string = keyVault.id
  output name string = keyVault.name
  output vaultUri string = keyVault.properties.vaultUri
  ```

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet } from 'types.bicep'

  @description('Deployment environment.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Role of this region in the active/passive design. Only the primary gets zone-redundant App Service capacity and the optional management VM.')
  @allowed([
    'primary'
    'secondary'
  ])
  param regionRole string

  @description('Azure region for this stamp.')
  param location string

  @description('Short lowercase region code used in resource names, for example wus3 or eus.')
  @minLength(2)
  @maxLength(4)
  param regionCode string

  @description('Hub and spoke address plan for this region.')
  param addressPlan regionAddressPlan

  @description('Central Log Analytics workspace resource ID from the global layer.')
  param logAnalyticsWorkspaceId string

  @description('Shared private DNS zone resource IDs from the global layer.')
  param privateDnsZoneIds privateDnsZoneSet

  @description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('Relative path probed by App Service health check.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM (primary region only).')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in this region. The warm standby leaves it off until failover.')
  param deployAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  @description('Application secrets written to this region\'s Key Vault, as { name: value } (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  var isProd = environmentName == 'prod'
  var isPrimary = regionRole == 'primary'
  var nameSuffix = uniqueString(subscription().id, environmentName, location)
  var availabilityZones = [
    '1'
    '2'
    '3'
  ]
  var names = {
    hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
    spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
    firewall: 'afw-defenstack-${environmentName}-${regionCode}'
    firewallPolicy: 'afwp-defenstack-${environmentName}-${regionCode}'
    firewallPublicIp: 'pip-afw-defenstack-${environmentName}-${regionCode}'
    storageAccount: 'st${regionCode}${nameSuffix}'
    keyVault: 'kv-${regionCode}-${nameSuffix}'
    appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
    appService: 'app-defenstack-${environmentName}-${regionCode}-${take(nameSuffix, 6)}'
    virtualMachine: 'vm${regionCode}${take(nameSuffix, 7)}'
    bastion: 'bas-defenstack-${environmentName}-${regionCode}'
    bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
    vpnGateway: 'vpng-defenstack-${environmentName}-${regionCode}'
    vpnGatewayPublicIp: 'pip-vpng-defenstack-${environmentName}-${regionCode}'
    appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module keyVault 'keyVault.bicep' = {
    name: 'key-vault'
    params: {
      location: location
      keyVaultName: names.keyVault
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      enablePurgeProtection: true
      enabledForTemplateDeployment: true
      enableDeleteLock: isProd
      secrets: keyVaultSecrets
    }
  }

  module hubNetwork 'hubNetwork.bicep' = {
    name: 'hub-network'
    params: {
      location: location
      vnetName: names.hubVnet
      addressSpace: addressPlan.hubAddressSpace
      firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
      bastionSubnetAddressPrefix: addressPlan.bastionSubnetPrefix
      gatewaySubnetAddressPrefix: addressPlan.gatewaySubnetPrefix
      firewallPrivateIp: firewallPrivateIp
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      bastionTargetAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      enableDeleteLock: isProd
    }
  }

  module azureFirewall 'azureFirewall.bicep' = {
    name: 'azure-firewall'
    params: {
      location: location
      firewallName: names.firewall
      firewallPolicyName: names.firewallPolicy
      publicIpName: names.firewallPublicIp
      firewallSubnetId: hubNetwork.outputs.firewallSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      managementAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      vpnClientAddressPrefixes: [
        addressPlan.vpnClientAddressPool
      ]
      allowedOutboundFqdns: allowedOutboundFqdns
      threatIntelMode: isProd ? 'Deny' : 'Alert'
      availabilityZones: availabilityZones
      firewallTier: 'Premium'
      idpsMode: isProd ? 'Deny' : 'Alert'
      enableDeleteLock: isProd
    }
  }

  module spokeNetwork 'spokeNetwork.bicep' = {
    name: 'spoke-network'
    params: {
      location: location
      vnetName: names.spokeVnet
      firewallPrivateIp: azureFirewall.outputs.privateIp
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      vnetAddressSpace: addressPlan.spokeAddressSpace
      privateEndpointSubnetAddressPrefix: addressPlan.privateEndpointSubnetPrefix
      appServiceIntegrationSubnetAddressPrefix: addressPlan.appServiceIntegrationSubnetPrefix
      virtualMachineSubnetAddressPrefix: addressPlan.managementSubnetPrefix
      approvedPrivateEndpointSourceCidrs: concat([
        addressPlan.appServiceIntegrationSubnetPrefix
        addressPlan.managementSubnetPrefix
        addressPlan.vpnClientAddressPool
      ], additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  // One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
  module appInsights 'appInsights.bicep' = {
    name: 'app-insights'
    params: {
      location: location
      componentName: names.appInsights
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module appService 'appService.bicep' = {
    name: 'app-service'
    params: {
      location: location
      appServiceAppName: names.appService
      appServicePlanName: names.appServicePlan
      environmentType: environmentName
      vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      healthCheckPath: healthCheckPath
      zoneRedundant: isProd && isPrimary
      instanceCount: isProd && isPrimary ? 3 : 1
      applicationInsightsConnectionString: appInsights.outputs.connectionString
    }
  }

  module appInsightsPublisher 'appInsightsPublisher.bicep' = {
    name: 'app-insights-publisher'
    params: {
      componentName: appInsights.outputs.name
      publisherPrincipalId: appService.outputs.appServicePrincipalId
      publisherAppServiceName: names.appService
    }
  }

  module virtualMachine 'virtualMachine.bicep' = if (enableVirtualMachine && isPrimary) {
    name: 'virtual-machine'
    params: {
      location: location
      vmName: names.virtualMachine
      osType: virtualMachineOsType
      subnetId: spokeNetwork.outputs.virtualMachineSubnetId
      adminUsername: virtualMachineAdminUsername
      adminSshPublicKey: virtualMachineAdminSshPublicKey
      adminPassword: virtualMachineAdminPassword
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      managementSourceCidrs: adminSourceCidrs
      adminGroupObjectId: adminGroupObjectId
    }
  }

  module bastion 'bastion.bicep' = if (deployAdminAccess) {
    name: 'bastion'
    params: {
      location: location
      bastionName: names.bastion
      publicIpName: names.bastionPublicIp
      subnetId: hubNetwork.outputs.bastionSubnetId
      availabilityZones: availabilityZones
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    // The hub resolves DNS through the firewall, so admin access waits for it.
    dependsOn: [
      azureFirewall
    ]
  }

  module vpnGateway 'vpnGateway.bicep' = if (deployAdminAccess) {
    name: 'vpn-gateway'
    params: {
      location: location
      gatewayName: names.vpnGateway
      publicIpNamePrefix: names.vpnGatewayPublicIp
      gatewaySubnetId: hubNetwork.outputs.gatewaySubnetId
      skuName: isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'
      availabilityZones: availabilityZones
      vpnClientAddressPool: addressPlan.vpnClientAddressPool
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    dependsOn: [
      azureFirewall
    ]
  }

  module networkIntegration 'networkIntegration.bicep' = {
    name: 'network-integration'
    params: {
      hubVnetName: names.hubVnet
      hubVnetId: hubNetwork.outputs.id
      spokeVnetName: names.spokeVnet
      spokeVnetId: spokeNetwork.outputs.id
      storageAccountName: names.storageAccount
      storageAccountId: storage.outputs.id
      storageContainerName: storage.outputs.blobContainerName
      appServicePrincipalId: appService.outputs.appServicePrincipalId
      appServiceName: names.appService
      useHubGateway: deployAdminAccess
    }
    // Gateway transit on the peering needs a provisioned gateway.
    dependsOn: [
      vpnGateway
    ]
  }

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
    }
  }

  module privateConnectivity 'privateConnectivity.bicep' = {
    name: 'private-connectivity'
    params: {
      location: location
      storageAccountId: storage.outputs.id
      storageAccountName: names.storageAccount
      appServiceId: appService.outputs.appServiceAppId
      appServiceName: names.appService
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      keyVaultId: keyVault.outputs.id
      keyVaultName: names.keyVault
      privateDnsZoneIds: privateDnsZoneIds
    }
  }

  output hubVnetName string = names.hubVnet
  output hubVnetId string = hubNetwork.outputs.id
  output spokeVnetName string = names.spokeVnet
  output spokeVnetId string = spokeNetwork.outputs.id
  output firewallPrivateIp string = azureFirewall.outputs.privateIp
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceId string = appService.outputs.appServiceAppId
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  output appInsightsName string = appInsights.outputs.name
  ```

  Replace `main.bicep`:

  ```bicep
  targetScope = 'subscription'

  import { regionAddressPlan, privateDnsZoneSet } from 'modules/types.bicep'

  @description('Deployment environment. Selects resource group names, redundancy, and deletion protection.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Primary (active) Azure region. Each allowed region has a short code in regionCodes.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param primaryLocation string = 'westus3'

  @description('Secondary (warm standby) Azure region, the platform pair of the primary.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param secondaryLocation string = 'eastus'

  @description('Deploy the secondary region stamp. Prod enables it; dev runs primary-only to halve cost.')
  param deploySecondaryRegion bool = false

  @description('Address plan for the primary region.')
  param primaryAddressPlan regionAddressPlan

  @description('Address plan for the secondary region. Required when deploySecondaryRegion is true.')
  param secondaryAddressPlan regionAddressPlan?

  @description('Approved outbound HTTPS destinations for both regions. Empty keeps application traffic denied.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges allowed to reach private endpoints over HTTPS in every region.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('Extra CIDR ranges allowed to administer management VMs over SSH/RDP, beyond the AzureBastionSubnet and VPN client pool of each region.')
  param managementSourceCidrs array = []

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the primary region.')
  param deployPrimaryAdminAccess bool = true

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the secondary region. Off in steady state; turned on during failover.')
  param deploySecondaryAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Custom domain served by Front Door, for example app.example.com, hosted at an external DNS provider. Empty serves only the azurefd.net hostname.')
  param customDomainHostName string = ''

  @description('Application secrets written to every regional Key Vault, as { name: value }. The pipeline supplies them from the KEYVAULT_SECRETS_JSON environment secret; never put values in a committed parameter file (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  @description('Relative path probed by App Service health check in every region.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM in the primary region.')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  var isProd = environmentName == 'prod'
  var regionCodes = {
    westus3: 'wus3'
    eastus: 'eus'
  }
  var primaryRegionCode = regionCodes[toLower(primaryLocation)]
  var secondaryRegionCode = regionCodes[toLower(secondaryLocation)]
  var globalResourceGroupName = 'rg-defenstack-${environmentName}-global'
  var primaryResourceGroupName = 'rg-defenstack-${environmentName}-${primaryRegionCode}'
  var secondaryResourceGroupName = 'rg-defenstack-${environmentName}-${secondaryRegionCode}'
  var privateDnsZoneNames privateDnsZoneSet = {
    blob: 'privatelink.blob.${environment().suffixes.storage}'
    sites: 'privatelink.azurewebsites.net'
    vault: 'privatelink.vaultcore.azure.net'
  }

  // Shared layer: Log Analytics and private DNS zones. Resource groups are pre-created (runbook 01).
  module global 'modules/global.bicep' = {
    name: 'global-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      location: primaryLocation
      workspaceName: 'log-defenstack-${environmentName}'
      privateDnsZoneNames: privateDnsZoneNames
      workspaceReplicationLocation: isProd && deploySecondaryRegion ? secondaryLocation : ''
      enableDeleteLock: isProd
    }
  }

  module primaryStamp 'modules/regionStamp.bicep' = {
    name: 'region-${primaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'primary'
      location: primaryLocation
      regionCode: primaryRegionCode
      addressPlan: primaryAddressPlan
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      enableVirtualMachine: enableVirtualMachine
      virtualMachineOsType: virtualMachineOsType
      virtualMachineAdminUsername: virtualMachineAdminUsername
      virtualMachineAdminSshPublicKey: virtualMachineAdminSshPublicKey
      virtualMachineAdminPassword: virtualMachineAdminPassword
      deployAdminAccess: deployPrimaryAdminAccess
      adminGroupObjectId: adminGroupObjectId
      keyVaultSecrets: keyVaultSecrets
    }
  }

  module secondaryStamp 'modules/regionStamp.bicep' = if (deploySecondaryRegion) {
    name: 'region-${secondaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'secondary'
      location: secondaryLocation
      regionCode: secondaryRegionCode
      addressPlan: secondaryAddressPlan!
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      deployAdminAccess: deploySecondaryAdminAccess
      primaryStorageAccountId: primaryStamp.outputs.storageAccountId
      primaryStorageAccountName: primaryStamp.outputs.storageAccountName
      keyVaultSecrets: keyVaultSecrets
    }
  }

  // The warm-standby App Service may read (never write) the primary application container (ADR-020).
  module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion) {
    name: 'storage-reader-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      storageAccountName: primaryStamp.outputs.storageAccountName
      storageContainerName: primaryStamp.outputs.storageContainerName
      readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
      readerAppServiceName: secondaryStamp!.outputs.appServiceName
    }
  }

  var primaryVirtualNetworks = [
    {
      name: primaryStamp.outputs.hubVnetName
      id: primaryStamp.outputs.hubVnetId
    }
    {
      name: primaryStamp.outputs.spokeVnetName
      id: primaryStamp.outputs.spokeVnetId
    }
  ]
  var secondaryVirtualNetworks = deploySecondaryRegion
    ? [
        {
          name: secondaryStamp!.outputs.hubVnetName
          id: secondaryStamp!.outputs.hubVnetId
        }
        {
          name: secondaryStamp!.outputs.spokeVnetName
          id: secondaryStamp!.outputs.spokeVnetId
        }
      ]
    : []

  // Origins in failover order: the primary region first (priority 1), then the warm standby (priority 2).
  var primaryOrigin = {
    name: 'app-${primaryRegionCode}'
    appServiceId: primaryStamp.outputs.appServiceId
    hostName: primaryStamp.outputs.appServiceHostName
    location: primaryLocation
  }
  var secondaryOrigins = deploySecondaryRegion
    ? [
        {
          name: 'app-${secondaryRegionCode}'
          appServiceId: secondaryStamp!.outputs.appServiceId
          hostName: secondaryStamp!.outputs.appServiceHostName
          location: secondaryLocation
        }
      ]
    : []

  // Public ingress: one Front Door per environment in the global resource group, after both stamps exist.
  module frontDoor 'modules/frontDoor.bicep' = {
    name: 'front-door-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      profileName: 'afd-defenstack-${environmentName}'
      endpointName: 'fde-defenstack-${environmentName}'
      wafPolicyName: 'wafdefenstack${environmentName}'
      origins: concat([
        primaryOrigin
      ], secondaryOrigins)
      healthProbePath: healthCheckPath
      customDomainHostName: customDomainHostName
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      enableDeleteLock: isProd
    }
  }

  // Link every region's hub (firewall DNS proxy) and spoke to each shared zone.
  module privateDnsLinks 'modules/privateDnsZoneLinks.bicep' = [for zone in items(privateDnsZoneNames): {
    name: 'dns-links-${zone.key}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      zoneName: zone.value
      virtualNetworks: concat(primaryVirtualNetworks, secondaryVirtualNetworks)
    }
  }]

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output frontDoorProfileName string = frontDoor.outputs.profileName
  output globalResourceGroupName string = globalResourceGroupName
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
  ```

  Replace `.github/workflows/deploy.yml`:

  ````yaml
  name: deploy

  on:
    push:
      branches: [main]
      paths:
        - 'main.bicep'
        - 'modules/**'
        - 'params/**'
    workflow_dispatch:
      inputs:
        environment:
          description: Target environment
          type: choice
          options: [dev, prod]
          default: dev

  permissions:
    contents: read
    id-token: write

  concurrency:
    group: deploy-${{ inputs.environment || 'dev' }}
    cancel-in-progress: false

  env:
    BICEP_VERSION: v0.47.16
    DEPLOYMENT_LOCATION: westus3
    TARGET_ENV: ${{ inputs.environment || 'dev' }}

  jobs:
    # Prod: runs in the reviewer-gated prod environment (approve plan, read the what-if, then approve apply) so every prod token needs approval.
    # Dev: runs in dev-plan (no reviewers).
    plan:
      if: github.ref == 'refs/heads/main'
      runs-on: ubuntu-latest
      environment: ${{ inputs.environment == 'prod' && 'prod' || 'dev-plan' }}
      steps:
        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"

        - name: Validate
          run: |
            az deployment sub validate \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --output none

        - name: What-if
          run: |
            set -o pipefail
            az deployment sub what-if \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --exclude-change-types Ignore NoChange 2>&1 \
              | sed -r 's/\x1B\[[0-9;]*[mK]//g' > whatif.txt
            {
              echo "### What-if: ${TARGET_ENV} (subscription scope, rg-defenstack-${TARGET_ENV}-*)"
              echo '```'
              head -c 60000 whatif.txt
              echo '```'
            } >> "$GITHUB_STEP_SUMMARY"

        - name: Keep the what-if for reviewers
          uses: actions/upload-artifact@v4
          with:
            name: whatif-${{ inputs.environment || 'dev' }}
            path: whatif.txt
            retention-days: 14
            if-no-files-found: error
            overwrite: true

    # Gated by the target environment's required reviewers (prod); reviewers read the plan job summary first.
    apply:
      needs: plan
      if: github.ref == 'refs/heads/main'
      runs-on: ubuntu-latest
      environment: ${{ inputs.environment || 'dev' }}
      steps:
        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"

        # Application secrets come from the environment secret KEYVAULT_SECRETS_JSON and are written to every regional vault (ADR-019).
        - name: Prepare Key Vault secrets
          shell: pwsh
          env:
            KEYVAULT_SECRETS_JSON: ${{ secrets.KEYVAULT_SECRETS_JSON }}
          run: ./scripts/ConvertTo-KeyVaultSecretsParameter.ps1 -Json $env:KEYVAULT_SECRETS_JSON -OutFile "$env:RUNNER_TEMP/keyvault-secrets.json"

        - name: Deploy
          run: |
            az deployment sub create \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --parameters keyVaultSecrets=@"$RUNNER_TEMP/keyvault-secrets.json" \
              --output table

        - name: Remove the secrets file
          if: always()
          run: rm -f "$RUNNER_TEMP/keyvault-secrets.json"

        # The approval wait can outlast the first login's token (up to 15 minutes per app), so refresh it immediately
        # before the step that needs it.
        - name: Refresh Azure login before approval
          uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        # Front Door reaches each App Service over Private Link; its connections stay Pending until approved (runbook 04).
        - name: Approve Front Door private endpoint connections
          shell: pwsh
          run: |
            $outputs = az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" --query properties.outputs --output json | ConvertFrom-Json
            $ids = $outputs.appServiceIds.value
            $profileName = $outputs.frontDoorProfileName.value
            $resourceGroupName = $outputs.globalResourceGroupName.value
            if ($LASTEXITCODE -ne 0 -or -not $ids) { throw 'Could not read appServiceIds from the deployment outputs.' }
            if (-not $profileName) { throw 'Could not read frontDoorProfileName from the deployment outputs.' }
            if (-not $resourceGroupName) { throw 'Could not read globalResourceGroupName from the deployment outputs.' }
            ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $ids -FrontDoorProfileName $profileName -FrontDoorResourceGroupName $resourceGroupName
  ````

- [ ] **Step 5: Build, lint, test, YAML, PSRule**

  Run `bicep build main.bicep` and lint every file. The full suite should show `Tests Passed: 371, Failed: 0`. The YAML check should print `YAML-OK`. PSRule should show 0 failures out of 871.

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/ConvertTo-KeyVaultSecretsParameter.ps1 tests/KeyVaultSecrets.Tests.ps1 modules/keyVault.bicep modules/regionStamp.bicep main.bicep main.json .github/workflows/deploy.yml
  git commit -m "feat: deploy-time Key Vault secrets written to every regional vault" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 4: Approval script refuses a matching request when no Front Door origin references the app (Phase 4 follow-up)

**Files:**
- Replace: `scripts/Approve-FrontDoorPrivateEndpoints.ps1`, `tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1`

**Interfaces:**
- **Consumes:** the script's existing `Find-MatchingOrigin`, `$pendingMatching`, `$FrontDoorProfileName` and `$OriginGroupName`.
- **Produces:** a new refusal. When there is no matching origin and `$pendingMatching` is non-empty, the script approves nothing and throws `<app>: a pending connection carries the request message '<message>' (<names>), but no Front Door origin in <profile>/<originGroup> references this App Service, so it cannot be Front Door's request. ... (runbook 04 section 5.2).` This also applies under `-WhatIf`.

- [ ] **Step 1: Write the failing tests**

  Three fixtures (WhatIf, delayed appearance, failing approve) now give the app a Pending origin, because Front Door always creates its origin before it sends the request. There are four new or renamed no-origin tests.

  Replace `tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $scriptPath = Get-RepoPath 'scripts/Approve-FrontDoorPrivateEndpoints.ps1'
      $appId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/app-defenstack-dev-wus3-abc123'
      $fdProfile = 'afd-defenstack-dev'
      $fdRg = 'rg-defenstack-dev-global'

      # Shadows the Azure CLI with a stateful fake: $global:FakeConnections holds the primary app's connections
      # (additional apps can be seeded through -AdditionalByAppId); $global:FakeOrigins holds the whole origin
      # group's origins (az afd origin list is not filtered per app, so every app in the loop sees the same list
      # and the script itself picks out the one whose sharedPrivateLinkResource.privateLink.id matches).
      # 'approve' flips a connection to Approved and, unless -OriginFlipsOnApproval is $false, flips the matching
      # origin to Approved too, modeling Front Door eventually catching up. Every call is recorded in $global:AzCalls.
      # az afd origin list/show print a FLATTENED shape: sharedPrivateLinkResource sits at the top level of each
      # origin, not nested under properties (runbook 04 uses this shape directly: --query sharedPrivateLinkResource.status).
      function New-Origin([string]$Name, [string]$Status, [string]$ForAppId = $appId) {
          [pscustomobject]@{
              name                      = $Name
              sharedPrivateLinkResource = [pscustomobject]@{
                  status      = $Status
                  privateLink = [pscustomobject]@{ id = $ForAppId }
              }
          }
      }

      # Older/alternate shape, nested under properties. The script must fall back to this when the top-level
      # sharedPrivateLinkResource property is absent.
      function New-NestedOrigin([string]$Name, [string]$Status, [string]$ForAppId = $appId) {
          [pscustomobject]@{
              name       = $Name
              properties = [pscustomobject]@{
                  sharedPrivateLinkResource = [pscustomobject]@{
                      status      = $Status
                      privateLink = [pscustomobject]@{ id = $ForAppId }
                  }
              }
          }
      }

      function Set-FakeConnections(
          [object[]]$Connections,
          [hashtable]$AdditionalByAppId = @{},
          [object[]]$Origins = @(),
          [bool]$OriginFlipsOnApproval = $true
      ) {
          $global:AzCalls = [System.Collections.Generic.List[string]]::new()
          $global:FakeConnections = [System.Collections.Generic.List[object]]::new()
          foreach ($c in $Connections) { $global:FakeConnections.Add($c) }

          $global:FakeConnectionsByApp = @{ $appId = $global:FakeConnections }
          foreach ($key in $AdditionalByAppId.Keys) {
              $list = [System.Collections.Generic.List[object]]::new()
              foreach ($c in $AdditionalByAppId[$key]) { $list.Add($c) }
              $global:FakeConnectionsByApp[$key] = $list
          }

          $global:FakeOrigins = [System.Collections.Generic.List[object]]::new()
          foreach ($o in $Origins) { $global:FakeOrigins.Add($o) }
          $global:FakeOriginFlipsOnApproval = $OriginFlipsOnApproval

          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              $global:LASTEXITCODE = 0
              if ($joined -like 'network private-endpoint-connection list*') {
                  $reqId = $args[[array]::IndexOf($args, '--id') + 1]
                  $list = $global:FakeConnectionsByApp[$reqId]
                  if (-not $list) { $list = @() }
                  return (ConvertTo-Json -InputObject @($list) -Depth 6)
              }
              if ($joined -like 'network private-endpoint-connection approve*') {
                  $id = $args[[array]::IndexOf($args, '--id') + 1]
                  $description = $args[[array]::IndexOf($args, '--description') + 1]
                  foreach ($appKey in $global:FakeConnectionsByApp.Keys) {
                      foreach ($c in $global:FakeConnectionsByApp[$appKey]) {
                          if ($c.id -eq $id) {
                              $c.properties.privateLinkServiceConnectionState.status = 'Approved'
                              $c.properties.privateLinkServiceConnectionState.description = $description
                          }
                      }
                  }
                  if ($global:FakeOriginFlipsOnApproval) {
                      $forAppId = ($id -split '/privateEndpointConnections/')[0]
                      foreach ($o in $global:FakeOrigins) {
                          $splr = if ($o.sharedPrivateLinkResource) { $o.sharedPrivateLinkResource } else { $o.properties.sharedPrivateLinkResource }
                          if ($splr -and $splr.privateLink.id -ieq $forAppId) {
                              $splr.status = 'Approved'
                          }
                      }
                  }
                  return ''
              }
              if ($joined -like 'afd origin list*') {
                  return (ConvertTo-Json -InputObject @($global:FakeOrigins) -Depth 6)
              }
              return ''
          }
      }

      function Remove-FakeConnections {
          Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
          Remove-Variable -Name FakeConnections -Scope Global -ErrorAction SilentlyContinue
          Remove-Variable -Name FakeConnectionsByApp -Scope Global -ErrorAction SilentlyContinue
          Remove-Variable -Name FakeOrigins -Scope Global -ErrorAction SilentlyContinue
          Remove-Variable -Name FakeOriginFlipsOnApproval -Scope Global -ErrorAction SilentlyContinue
          Remove-Variable -Name AzCalls -Scope Global -ErrorAction SilentlyContinue
          Remove-Variable -Name ListCallCount -Scope Global -ErrorAction SilentlyContinue
      }

      function New-Connection(
          [string]$Name,
          [string]$Status,
          [string]$Description,
          [string]$ForAppId = $appId,
          [string]$PrivateEndpointId
      ) {
          if (-not $PrivateEndpointId) {
              $PrivateEndpointId = "$ForAppId-privateEndpoints-pe-$Name"
          }
          [pscustomobject]@{
              id         = "$ForAppId/privateEndpointConnections/$Name"
              name       = $Name
              properties = [pscustomobject]@{
                  privateLinkServiceConnectionState = [pscustomobject]@{ status = $Status; description = $Description }
                  privateEndpoint                   = [pscustomobject]@{ id = $PrivateEndpointId }
              }
          }
      }

      function Get-Approvals { @($global:AzCalls | Where-Object { $_ -like 'network private-endpoint-connection approve*' }) }
  }

  Describe 'Approve-FrontDoorPrivateEndpoints.ps1 (Phase 4)' {
      AfterEach { Remove-FakeConnections }

      It 'exists, parses, and supports -WhatIf, with the Front Door origin parameters' {
          $scriptPath | Should -Exist
          $tokens = $null; $errors = $null
          [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
          $errors | Should -BeNullOrEmpty
          $command = Get-Command $scriptPath
          $command.Parameters.Keys | Should -Contain 'WhatIf'
          $command.Parameters.Keys | Should -Contain 'FrontDoorProfileName'
          $command.Parameters.Keys | Should -Contain 'FrontDoorResourceGroupName'
          $command.Parameters.Keys | Should -Contain 'OriginGroupName'
          $command.Parameters['FrontDoorProfileName'].Attributes.Mandatory | Should -Contain $true
          $command.Parameters['FrontDoorResourceGroupName'].Attributes.Mandatory | Should -Contain $true
      }

      It 'rejects an ID that is not an App Service' {
          { & $scriptPath -AppServiceId '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv' -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg } |
              Should -Throw '*does not match*'
      }

      It 'approves a pending Front Door connection and keeps the request message as the description prefix' {
          Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin 'app-wus3' 'Pending')
          & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null
          $approvals = @(Get-Approvals)
          $approvals.Count | Should -Be 1
          $approvals[0] | Should -BeLike "*--id $appId/privateEndpointConnections/fd-1 *"
          $global:FakeConnections[0].properties.privateLinkServiceConnectionState.description | Should -BeLike 'defenstack-frontdoor*'
      }

      It 'never approves a pending connection with a different request message' {
          Set-FakeConnections -Connections @(
              New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1'
              New-Connection 'someone-else' 'Pending' 'please approve me'
          ) -Origins @(New-Origin 'app-wus3' 'Approved')
          & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
          Get-Approvals | Should -BeNullOrEmpty
          $global:FakeConnections[1].properties.privateLinkServiceConnectionState.status | Should -Be 'Pending'
          ($warnings -join ' ') | Should -Match 'someone-else'
      }

      It 'returns without approving when the Front Door connection is already approved' {
          Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1') -Origins @(New-Origin 'app-wus3' 'Approved')
          { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Not -Throw
          Get-Approvals | Should -BeNullOrEmpty
      }

      It 'fails when no Front Door connection is approved before the timeout (origin exists but never reaches Approved)' {
          Set-FakeConnections -Connections @() -Origins @(New-Origin 'app-wus3' 'Pending')
          { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*no Front Door private endpoint connection was approved*'
      }

      It 'makes no approval under -WhatIf' {
          Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin 'app-wus3' 'Pending')
          & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -WhatIf | Out-Null
          Get-Approvals | Should -BeNullOrEmpty
      }

      It 'fails when the Azure CLI cannot list connections' {
          Set-FakeConnections -Connections @()
          function global:az { $global:LASTEXITCODE = 1; return '' }
          { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*Unable to list private endpoint connections*'
      }

      It 'approves the Front Door connection and leaves an unrelated connection untouched (regression: JSON array unrolling on PS 5.1)' {
          Set-FakeConnections -Connections @(
              New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor'
              New-Connection 'unrelated' 'Approved' 'some other service'
          ) -Origins @(New-Origin 'app-wus3' 'Pending')
          & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null
          $approvals = @(Get-Approvals)
          $approvals.Count | Should -Be 1
          $approvals[0] | Should -BeLike "*--id $appId/privateEndpointConnections/fd-1 *"
          $global:FakeConnections[1].properties.privateLinkServiceConnectionState.status | Should -Be 'Approved'
          $global:FakeConnections[1].properties.privateLinkServiceConnectionState.description | Should -Be 'some other service'
      }

      It 'includes the private endpoint id in the approval output' {
          Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor' -PrivateEndpointId '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Network/privateEndpoints/pe-fd-1') -Origins @(New-Origin 'app-wus3' 'Pending')
          $output = & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0
          ($output -join ' ') | Should -Match ([regex]::Escape('(private endpoint /subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Network/privateEndpoints/pe-fd-1)'))
      }

      It 'refuses to approve when a Front Door connection is already approved and another pending connection shares the same request message (possible spoofing)' {
          Set-FakeConnections -Connections @(
              New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1'
              New-Connection 'fd-2' 'Pending' 'defenstack-frontdoor'
          )
          { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*fd-2*'
          Get-Approvals | Should -BeNullOrEmpty
      }

      It 'refuses to approve when more than one pending connection shares the same request message (possible spoofing)' {
          Set-FakeConnections -Connections @(
              New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor'
              New-Connection 'fd-2' 'Pending' 'defenstack-frontdoor'
          )
          { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*fd-1*'
          Get-Approvals | Should -BeNullOrEmpty
      }

      It 'approves a Front Door connection that appears a few polls after the deployment' {
          Set-FakeConnections -Connections @()
          $global:ListCallCount = 0
          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              $global:LASTEXITCODE = 0
              if ($joined -like 'network private-endpoint-connection list*') {
                  $global:ListCallCount++
                  if ($global:ListCallCount -ge 2 -and $global:FakeConnections.Count -eq 0) {
                      $global:FakeConnections.Add((New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor'))
                  }
                  return (ConvertTo-Json -InputObject @($global:FakeConnections) -Depth 6)
              }
              if ($joined -like 'network private-endpoint-connection approve*') {
                  $id = $args[[array]::IndexOf($args, '--id') + 1]
                  $description = $args[[array]::IndexOf($args, '--description') + 1]
                  foreach ($c in $global:FakeConnections) {
                      if ($c.id -eq $id) {
                          $c.properties.privateLinkServiceConnectionState.status = 'Approved'
                          $c.properties.privateLinkServiceConnectionState.description = $description
                      }
                  }
                  $global:FakeOrigins.Clear()
                  $global:FakeOrigins.Add((New-Origin 'app-wus3' 'Approved'))
                  return ''
              }
              if ($joined -like 'afd origin list*') {
                  return (ConvertTo-Json -InputObject @($global:FakeOrigins) -Depth 6)
              }
              return ''
          }
          $global:FakeOrigins = [System.Collections.Generic.List[object]]::new()
          $global:FakeOrigins.Add((New-Origin 'app-wus3' 'Pending'))
          & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 5 -PollIntervalSeconds 1 | Out-Null
          (Get-Approvals).Count | Should -Be 1
      }

      It 'approves Front Door connections on two apps given as separate IDs' {
          $appId2 = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/app-defenstack-dev-wus3-def456'
          Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -AdditionalByAppId @{
              $appId2 = @(New-Connection -Name 'fd-2' -Status 'Pending' -Description 'defenstack-frontdoor' -ForAppId $appId2)
          } -Origins @(
              New-Origin -Name 'app-wus3' -Status 'Pending' -ForAppId $appId
              New-Origin -Name 'app-eus' -Status 'Pending' -ForAppId $appId2
          )
          & $scriptPath -AppServiceId @($appId, $appId2) -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null
          (Get-Approvals).Count | Should -Be 2
      }

      It 'fails when the Azure CLI cannot approve a connection' {
          Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              if ($joined -like 'network private-endpoint-connection list*') {
                  $global:LASTEXITCODE = 0
                  return (ConvertTo-Json -InputObject @($global:FakeConnections) -Depth 6)
              }
              if ($joined -like 'network private-endpoint-connection approve*') {
                  $global:LASTEXITCODE = 1
                  return ''
              }
              $global:LASTEXITCODE = 0
              if ($joined -like 'afd origin list*') {
                  return (ConvertTo-Json -InputObject @(New-Origin 'app-wus3' 'Pending') -Depth 6)
              }
              return ''
          }
          { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*Approving private endpoint connection*'
      }

      Context 'Front Door origin status is the source of truth for success (final review A)' {
          It 'succeeds only once the matching Front Door origin reports its private link Approved' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin 'app-wus3' 'Pending')
              $output = & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0
              (Get-Approvals).Count | Should -Be 1
              ($output -join ' ') | Should -Match "Front Door origin 'app-wus3' reports its private link Approved"
          }

          It 'throws a distinct message when the connection it approved does not bring the origin to Approved (possible spoofed request)' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin 'app-wus3' 'Pending') -OriginFlipsOnApproval $false
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 2 -PollIntervalSeconds 1 | Out-Null } |
                  Should -Throw '*did not bring Front Door*origin*to Approved*may not be Front Door*'
              (Get-Approvals).Count | Should -Be 1
          }

          It 'succeeds without approving anything when a manually approved connection lacks the prefix but the origin already reports Approved' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Approved' 'approved manually by an operator') -Origins @(New-Origin 'app-wus3' 'Approved')
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Not -Throw
              Get-Approvals | Should -BeNullOrEmpty
          }

          It 'refuses, and approves nothing, when a matching request exists but no Front Door origin references the App Service (Phase 5)' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @()
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                  Should -Throw "*no Front Door origin in $fdProfile/app references this App Service, so it cannot be Front Door's request*"
              Get-Approvals | Should -BeNullOrEmpty
          }

          It 'refuses even when only an origin for a different App Service exists (Phase 5)' {
              $otherAppId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/some-other-app'
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin -Name 'app-other' -Status 'Pending' -ForAppId $otherAppId)
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                  Should -Throw "*cannot be Front Door's request*"
              Get-Approvals | Should -BeNullOrEmpty
          }

          It 'refuses under -WhatIf too, without approving' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @()
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -WhatIf | Out-Null } |
                  Should -Throw "*cannot be Front Door's request*"
              Get-Approvals | Should -BeNullOrEmpty
          }

          It 'still times out with the "no origin" message when there is neither a request nor an origin' {
              Set-FakeConnections -Connections @() -Origins @()
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                  Should -Throw "*no Front Door origin in $fdProfile/app references this App Service*"
          }

          It 'fails when the Azure CLI cannot list Front Door origins' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
              function global:az {
                  $joined = $args -join ' '
                  $global:AzCalls.Add($joined)
                  if ($joined -like 'network private-endpoint-connection list*') {
                      $global:LASTEXITCODE = 0
                      $reqId = $args[[array]::IndexOf($args, '--id') + 1]
                      $list = $global:FakeConnectionsByApp[$reqId]
                      if (-not $list) { $list = @() }
                      return (ConvertTo-Json -InputObject @($list) -Depth 6)
                  }
                  if ($joined -like 'network private-endpoint-connection approve*') {
                      $global:LASTEXITCODE = 0
                      return ''
                  }
                  if ($joined -like 'afd origin list*') {
                      $global:LASTEXITCODE = 1
                      return ''
                  }
                  $global:LASTEXITCODE = 0
                  return ''
              }
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                  Should -Throw '*Unable to list Front Door origins*'
          }

          It 'does not approve a pending connection whose request message differs only in case (case-sensitive match)' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'DEFENSTACK-FRONTDOOR') -Origins @(New-Origin 'app-wus3' 'Pending')
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 -WarningAction SilentlyContinue | Out-Null } |
                  Should -Throw '*no Front Door private endpoint connection was approved*'
              Get-Approvals | Should -BeNullOrEmpty
          }

          It 'recognizes the origin private link status and id when sharedPrivateLinkResource is nested under properties (fallback shape)' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-NestedOrigin 'app-wus3' 'Pending')
              & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null
              (Get-Approvals).Count | Should -Be 1
          }
      }

      Context 'origin status refuses a prefix-less approval that spoofs a pending request (final fix 2, C2)' {
          It 'throws and approves nothing when a connection is Approved without the prefix, the origin already reports Approved, and a Pending exact-message request also exists' {
              Set-FakeConnections -Connections @(
                  New-Connection 'fd-1' 'Approved' 'approved manually by an operator'
                  New-Connection 'fd-2' 'Pending' 'defenstack-frontdoor'
              ) -Origins @(New-Origin 'app-wus3' 'Approved')
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                  Should -Throw '*already*Approved*cannot be Front Door*fd-2*'
              Get-Approvals | Should -BeNullOrEmpty
          }
      }

      Context 'distinct timeout message when a prefixed connection is already approved but the origin lags (final fix 2, C3)' {
          It 'throws a message naming the origin and its status when the connection was already Approved before this run and the origin never reaches Approved' {
              Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1') -Origins @(New-Origin 'app-wus3' 'Pending')
              { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                  Should -Throw "*a Front Door connection is approved but origin 'app-wus3' still reports 'Pending' after 0 seconds*runbook 04 section 9*"
              Get-Approvals | Should -BeNullOrEmpty
          }
      }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected: the no-origin refusal tests fail, because the old script approves `fd-1`.

- [ ] **Step 3: Add the refusal**

  Replace `scripts/Approve-FrontDoorPrivateEndpoints.ps1`:

  ```powershell
  <#
  .SYNOPSIS
  Approves the pending private endpoint connections that Azure Front Door creates on each App Service origin, and
  waits until Front Door's own origin status confirms the Private Link is Approved.

  .DESCRIPTION
  Front Door reaches every App Service over Private Link. Each origin creates a private endpoint connection on the
  app that stays Pending until someone approves it, and until then Front Door returns errors for that origin.
  This script approves only connections whose request message is the one modules/frontDoor.bicep sets
  (defenstack-frontdoor by default). Any other pending connection is reported and left alone.

  Because the request message is free text, a third party could set the same message on an unrelated private
  endpoint request. To guard against that, for each app:
    - A pending connection whose request message does not match is always left alone (warned about, never
      approved).
    - If a Front Door connection is already Approved (its description starts with the request message) and
      another pending connection also carries the exact request message, nothing is approved. The script throws,
      naming the pending connection(s), so an operator can verify them before approving by hand (runbook 04
      section 5.2).
    - If more than one pending connection carries the exact request message and none is approved yet, nothing is
      approved either, and the script throws the same way.
    - Otherwise, when exactly one pending connection carries the exact request message and none is approved yet,
      that connection is approved and its private endpoint id is reported.
    Every request message comparison is case-sensitive (ordinal), so a message that differs only in case is
    treated as unrelated, never approved.

  An approved connection is not, by itself, proof that Front Door is using it: approving is this script's own
  action, and a stale or unrelated connection could coincidentally be approved by someone else. The script
  therefore waits for Front Door's own view, the origin group's `sharedPrivateLinkResource.status`, read with
  `az afd origin list`, to report Approved for the origin whose private link targets this app. Only then is the
  app done. If this run approved a connection but the origin never reaches Approved by the deadline, the script
  throws a distinct message, because the connection it approved may not be the one Front Door is actually using.
  If no origin in the given profile/origin group references the app at all, it throws a different message once
  the deadline passes.

  Runs in deploy.yml after the deployment, and by hand from runbook 04.

  A matching Pending request for an App Service that no origin in the origin group references is refused (the
  script approves nothing and throws): Front Door creates its origin before it sends the request, so such a request
  cannot be Front Door's.

  .EXAMPLE
  ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId /subscriptions/<sub>/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/<app> -FrontDoorProfileName afd-defenstack-dev -FrontDoorResourceGroupName rg-defenstack-dev-global
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
      [Parameter(Mandatory)]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$')]
      [string[]]$AppServiceId,

      [Parameter(Mandatory)]
      [ValidatePattern('^[A-Za-z0-9-]{1,90}$')]
      [string]$FrontDoorProfileName,

      [Parameter(Mandatory)]
      [ValidatePattern('^[-\w._()]{1,90}$')]
      [string]$FrontDoorResourceGroupName,

      [Parameter()]
      [ValidatePattern('^[A-Za-z0-9-]{1,90}$')]
      [string]$OriginGroupName = 'app',

      [Parameter()]
      [ValidatePattern('^[A-Za-z0-9-]{1,64}$')]
      [string]$RequestMessage = 'defenstack-frontdoor',

      [Parameter()]
      [ValidateRange(0, 3600)]
      [int]$TimeoutSeconds = 900,

      [Parameter()]
      [ValidateRange(1, 300)]
      [int]$PollIntervalSeconds = 30
  )

  $ErrorActionPreference = 'Stop'

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
      throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
  }

  # The approval description keeps the request message as a prefix, so an approved Front Door connection stays recognizable.
  $approvalDescription = "$RequestMessage approved by Approve-FrontDoorPrivateEndpoints.ps1"

  function Get-PrivateEndpointConnections([string]$ResourceId) {
      $json = az network private-endpoint-connection list --id $ResourceId --output json
      if ($LASTEXITCODE -ne 0) {
          throw "Unable to list private endpoint connections for $ResourceId."
      }
      # On Windows PowerShell 5.1, ConvertFrom-Json does not reliably unroll a JSON array when the result is
      # wrapped directly in @(...): several connections can collapse into a single merged object instead of
      # staying separate. Force the unroll with ForEach-Object so each connection stays its own object (and an
      # empty or missing array becomes zero items).
      $parsed = ($json -join "`n") | ConvertFrom-Json
      @($parsed | ForEach-Object { $_ })
  }

  function Get-FrontDoorOrigins {
      $json = az afd origin list --profile-name $FrontDoorProfileName --resource-group $FrontDoorResourceGroupName --origin-group-name $OriginGroupName --output json
      if ($LASTEXITCODE -ne 0) {
          throw "Unable to list Front Door origins for $FrontDoorProfileName/$FrontDoorResourceGroupName/$OriginGroupName."
      }
      # Same Windows PowerShell 5.1 array-unrolling guard as Get-PrivateEndpointConnections.
      $parsed = ($json -join "`n") | ConvertFrom-Json
      @($parsed | ForEach-Object { $_ })
  }

  # `az afd origin list`/`show` print a FLATTENED shape: sharedPrivateLinkResource sits at the top level of each
  # origin object, not nested under properties (runbook 04 uses this shape directly: --query
  # sharedPrivateLinkResource.status). Fall back to properties.sharedPrivateLinkResource only when the top-level
  # property is absent, in case an older/alternate shape is ever returned.
  function Get-SharedPrivateLinkResource($origin) {
      if ($origin.sharedPrivateLinkResource) {
          return $origin.sharedPrivateLinkResource
      }
      if ($origin.properties -and $origin.properties.sharedPrivateLinkResource) {
          return $origin.properties.sharedPrivateLinkResource
      }
      return $null
  }

  function Find-MatchingOrigin([object[]]$Origins, [string]$ResourceId) {
      $Origins | Where-Object {
          $splr = Get-SharedPrivateLinkResource $_
          $splr -and $splr.privateLink -and [string]$splr.privateLink.id -ieq $ResourceId
      } | Select-Object -First 1
  }

  foreach ($id in $AppServiceId) {
      $appName = ($id -split '/')[-1]
      $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
      $approvedConnectionForApp = $null
      $matchingOrigin = $null
      while ($true) {
          $connections = Get-PrivateEndpointConnections $id
          $states = $connections | ForEach-Object {
              [pscustomobject]@{
                  Id                = $_.id
                  Name              = $_.name
                  Status            = $_.properties.privateLinkServiceConnectionState.status
                  Description       = [string]$_.properties.privateLinkServiceConnectionState.description
                  PrivateEndpointId = $_.properties.privateEndpoint.id
              }
          }

          # Every comparison against $RequestMessage is case-sensitive (ordinal): a message that differs only in
          # case belongs to someone else, never to Front Door.
          $approvedFrontDoor = @($states | Where-Object { $_.Status -ceq 'Approved' -and $_.Description.StartsWith($RequestMessage, [StringComparison]::Ordinal) })
          $pendingMatching = @($states | Where-Object { $_.Status -ceq 'Pending' -and $_.Description -ceq $RequestMessage })
          $pendingOther = @($states | Where-Object { $_.Status -ceq 'Pending' -and $_.Description -cne $RequestMessage })

          foreach ($other in $pendingOther) {
              Write-Warning "$appName`: leaving pending connection '$($other.Name)' (request message '$($other.Description)'): not a Front Door request from this deployment."
          }

          # Read Front Door's own origin status before deciding whether to approve anything. The "already approved"
          # refusal below only catches a connection whose description starts with the request message; a connection
          # approved another way (for example, by hand in the portal, without the prefix) would not match it. Once
          # Front Door's own origin reports its private link Approved, any pending connection with the same request
          # message cannot be Front Door's either way, so check this first (runbook 04 section 5.2).
          $origins = Get-FrontDoorOrigins
          $matchingOrigin = Find-MatchingOrigin $origins $id
          $matchingOriginStatus = if ($matchingOrigin) { (Get-SharedPrivateLinkResource $matchingOrigin).status } else { $null }

          if ($matchingOriginStatus -eq 'Approved' -and $pendingMatching.Count -gt 0) {
              $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
              throw "$appName`: Front Door's origin '$($matchingOrigin.name)' already reports its private link Approved, so the pending connection with the same request message ('$RequestMessage') cannot be Front Door's ($names). This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
          }

          # Front Door creates its origin first and only then sends the private endpoint request, so a matching
          # request for an App Service that no origin references cannot be Front Door's.
          if (-not $matchingOrigin -and $pendingMatching.Count -gt 0) {
              $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
              throw "$appName`: a pending connection carries the request message '$RequestMessage' ($names), but no Front Door origin in $FrontDoorProfileName/$OriginGroupName references this App Service, so it cannot be Front Door's request. This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
          }

          if ($approvedFrontDoor.Count -gt 0 -and $pendingMatching.Count -gt 0) {
              $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
              throw "$appName`: a Front Door connection is already approved, but a pending connection with the same request message ('$RequestMessage') also exists ($names). This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
          }

          if ($pendingMatching.Count -gt 1) {
              $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
              throw "$appName`: multiple pending connections share the request message '$RequestMessage' ($names). This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
          }

          if ($approvedFrontDoor.Count -eq 0 -and $pendingMatching.Count -eq 1) {
              $pending = $pendingMatching[0]
              if ($PSCmdlet.ShouldProcess($pending.Name, "Approve Front Door private endpoint connection on $appName")) {
                  az network private-endpoint-connection approve --id $pending.Id --description $approvalDescription --output none
                  if ($LASTEXITCODE -ne 0) {
                      throw "Approving private endpoint connection '$($pending.Name)' on $appName failed."
                  }
                  Write-Output "$appName`: approved Front Door connection '$($pending.Name)' (private endpoint $($pending.PrivateEndpointId))."
                  $approvedConnectionForApp = $pending
              }
          }

          if ($WhatIfPreference) {
              break
          }

          # Approving a connection is this script's own action, not proof Front Door is using it. Trust only
          # Front Door's own origin status for success. Re-read it: approving above may have just flipped it.
          $origins = Get-FrontDoorOrigins
          $matchingOrigin = Find-MatchingOrigin $origins $id
          $matchingOriginStatus = if ($matchingOrigin) { (Get-SharedPrivateLinkResource $matchingOrigin).status } else { $null }

          if ($matchingOriginStatus -eq 'Approved') {
              Write-Output "$appName`: Front Door origin '$($matchingOrigin.name)' reports its private link Approved."
              break
          }

          if ((Get-Date) -ge $deadline) {
              if (-not $matchingOrigin) {
                  throw "$appName`: no Front Door origin in $FrontDoorProfileName/$OriginGroupName references this App Service. Check the origin exists, or redeploy (runbook 04 section 9)."
              }
              if ($approvedConnectionForApp) {
                  throw "$appName`: the approved connection '$($approvedConnectionForApp.Name)' (private endpoint $($approvedConnectionForApp.PrivateEndpointId)) did not bring Front Door's origin '$($matchingOrigin.name)' to Approved within $TimeoutSeconds seconds; it may not be Front Door's request. Reject it and follow runbook 04 section 5.2."
              }
              if ($approvedFrontDoor.Count -gt 0) {
                  throw "$appName`: a Front Door connection is approved but origin '$($matchingOrigin.name)' still reports '$matchingOriginStatus' after $TimeoutSeconds seconds; check the origin in the Front Door profile (runbook 04 section 9)."
              }
              throw "$appName`: no Front Door private endpoint connection was approved within $TimeoutSeconds seconds. Check the origin in the Front Door profile, then re-run this script (runbook 04 section 9)."
          }
          Write-Output "$appName`: waiting for Front Door to create its private endpoint connection..."
          Start-Sleep -Seconds $PollIntervalSeconds
      }
  }
  ```

- [ ] **Step 4: Run the tests**

  Run the script test file: 27 of 27 pass. The full suite should show `Tests Passed: 374, Failed: 0`.

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/Approve-FrontDoorPrivateEndpoints.ps1 tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1
  git commit -m "fix: refuse Front Door approval when no origin references the App Service" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 5: Runbook 05, ADR-019/020/021, and Phase 5 documentation updates

**Files:**
- Create: `docs/runbooks/05-app-and-data.md`, `docs/decisions/ADR-019-deploy-time-key-vault-secrets.md`, `docs/decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md`, `docs/decisions/ADR-021-application-insights-per-region.md`
- Replace: `tests/Docs.Tests.ps1`
- Modify: `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/00b-configure-pipeline-credentials.md`, `docs/runbooks/00-pipeline-and-identity.md`, `docs/runbooks/01-deploy-stack.md`, `docs/runbooks/04-ingress.md`, `README.md`

**Interfaces:**
- **Consumes:** the names, parameters, roles, scripts and messages from Tasks 1–4. The runbook quotes them verbatim.
- **Produces:** the documents that the spec §6 definition of done requires a human to execute in dev.

- [ ] **Step 1: Write the failing docs tests**

  Replace `tests/Docs.Tests.ps1`:

  ````powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
  }

  Describe 'Phase 1 documentation' {
      It '<_> exists' -ForEach 'docs/architecture/overview.md', 'docs/runbooks/01-deploy-stack.md', 'docs/runbooks/01a-migrate-from-defenstack.md', 'docs/decisions/ADR-008-warm-standby-and-dev-single-region.md', 'docs/decisions/ADR-009-subscription-scope-pipeline-identity.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It '<_> follows the 9-section runbook template' -ForEach 'docs/runbooks/01-deploy-stack.md', 'docs/runbooks/01a-migrate-from-defenstack.md' {
          $text = Get-Content (Get-RepoPath $_) -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the architecture overview contains mermaid diagrams' {
          Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw | Should -Match '```mermaid'
      }
  }

  Describe 'README reflects the subscription-scope layout' {
      BeforeAll {
          $script:readmeText = Get-Content (Get-RepoPath 'README.md') -Raw
          $script:teardownHeading = '### Safe teardown'
          $script:beforeTeardown = $script:readmeText.Substring(0, $script:readmeText.IndexOf($script:teardownHeading))
      }

      It 'does not contain a param environmentType assignment before the legacy Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'param environmentType'
      }

      It 'does not contain an environmentType= CLI argument before the legacy Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'environmentType='
      }

      It 'does not mention spokeVnetAddressSpace' {
          $script:readmeText | Should -Not -Match 'spokeVnetAddressSpace'
      }

      It 'does not mention a virtual-machines subnet' {
          $script:readmeText | Should -Not -Match 'virtual-machines'
      }

      It 'only uses az deployment group inside or after the Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'az deployment group'
      }
  }

  Describe 'Phase 2 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/02-firewall.md', 'docs/decisions/ADR-010-shared-firewall-rules-module.md', 'docs/decisions/ADR-011-tls-inspection-deferred.md', 'docs/decisions/ADR-012-prod-two-approval-deploys.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the firewall runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/02-firewall.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the firewall runbook documents the rule change and allowlist request procedures' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/02-firewall.md') -Raw
          $text | Should -Match 'Rule change procedure'
          $text | Should -Match 'Allowlist request'
      }

      It 'runbook 00b documents the dev-plan environment and the prod two-approval design' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
          $text | Should -Match 'dev-plan'
          $text | Should -Match 'two approvals'
          $text | Should -Match 'no `?prod-plan`? environment'
      }
  }

  Describe 'Phase 3 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/03-admin-access.md', 'docs/decisions/ADR-013-admin-access-network-paths.md', 'docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md', 'docs/decisions/ADR-015-vpn-gateway-sku-and-active-active.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the admin access runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the admin access runbook covers VPN client setup per OS, Bastion connect, and break-glass (spec §5 Phase 3)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
          foreach ($topic in 'Windows 10/11', 'macOS', 'Linux (Ubuntu', 'Connect through Bastion', 'Break-glass') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the admin access runbook restricts the VPN app to the admin group' {
          Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw | Should -Match 'appRoleAssignmentRequired=true'
      }

      It 'the architecture overview draws the admin flow and lists the Phase 3 ADRs' {
          $text = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          $text | Should -Match 'VPN gateway \(GatewaySubnet'
          foreach ($adr in 'ADR-013', 'ADR-014', 'ADR-015') { $text | Should -Match $adr }
      }

      It 'the cost document has a Phase 3 delta' {
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 3 delta'
      }
  }

  Describe 'Phase 4 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/04-ingress.md', 'docs/decisions/ADR-016-front-door-over-application-gateway.md', 'docs/decisions/ADR-017-ddos-network-protection-not-selected.md', 'docs/decisions/ADR-018-front-door-placement-and-private-link-approval.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the ingress runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the ingress runbook covers DNS cutover, WAF tuning and exclusions, and PE approval (spec §5 Phase 4)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          foreach ($topic in 'Custom domain and DNS cutover', 'WAF tuning and exclusions', 'Approving a private endpoint connection by hand', 'az network private-endpoint-connection approve', 'The request message is not proof') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the ingress runbook validates the spec checks: Front Door 200, WAF 403, direct App Service 403' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          $text | Should -Match ([regex]::Escape('?q=<script>alert(1)</script>'))
          $text | Should -Match ([regex]::Escape('https://<app>.azurewebsites.net/'))
      }

      It 'the ingress runbook documents that success is Front Door''s own origin status (final review A)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          $text | Should -Match ([regex]::Escape('sharedPrivateLinkResource.status'))
      }

      It 'the architecture overview draws the ingress flow and lists the Phase 4 ADRs' {
          $text = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          $text | Should -Match 'Azure Front Door Premium \(global'
          foreach ($adr in 'ADR-016', 'ADR-017', 'ADR-018') { $text | Should -Match $adr }
      }

      It 'the cost document has a Phase 4 delta' {
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 4 delta'
      }
  }

  Describe 'Phase 5 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/05-app-and-data.md', 'docs/decisions/ADR-019-deploy-time-key-vault-secrets.md', 'docs/decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md', 'docs/decisions/ADR-021-application-insights-per-region.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the app and data runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the app and data runbook covers secret sync and restore from soft delete and PITR (spec §5 Phase 5)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw
          foreach ($topic in 'Secret sync', 'KEYVAULT_SECRETS_JSON', 'az storage blob undelete', 'az storage container restore', 'az storage blob restore', 'az keyvault secret recover') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'runbook 00b documents the environment secret and the Phase 5 delegatable roles' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
          $text | Should -Match 'KEYVAULT_SECRETS_JSON'
          $text | Should -Match '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
          $text | Should -Match '3913510d-42f4-4e42-8a64-420c390055eb'
      }

      It 'the architecture overview and cost document cover Phase 5' {
          $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          foreach ($adr in 'ADR-019', 'ADR-020', 'ADR-021') { $overview | Should -Match $adr }
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 5 delta'
      }

      It 'runbook 04 documents the no-origin refusal' {
          Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw | Should -Match ([regex]::Escape("so it cannot be Front Door's request"))
      }
  }
  ````

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected: the `Phase 5 documentation` tests fail.

- [ ] **Step 3: Create runbook 05**

  Create `docs/runbooks/05-app-and-data.md`:

  ````markdown
  # 05 - App and data runbook (storage resilience, Application Insights, deploy-time secrets)

  > Owning module(s): `modules/storage.bicep`, `modules/storageSecondaryEndpoint.bicep`, `modules/storageReaderAssignment.bicep`, `modules/appInsights.bicep`, `modules/appInsightsPublisher.bicep`, `modules/appService.bicep`, `modules/keyVault.bicep`, wired by `modules/regionStamp.bicep` and `main.bicep`. Pipeline: `.github/workflows/deploy.yml` with `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Identity and secrets" and "Data and application resilience", §5 Phase 5.

  ## 1. Purpose and scope

  This runbook makes each region's application data and secrets survive the failures the design plans for, and makes the app observable.

  **Storage (`modules/storage.bicep`, per stamp):**

  | Stamp | SKU | Why |
  |---|---|---|
  | Prod primary (West US 3) | `Standard_RAGZRS` | Zone-redundant in West US 3, geo-copied to East US, with a read-only secondary endpoint (`ADR-020`) |
  | Prod warm standby (East US) | `Standard_GRS` | The standby's own state; geo-copied to its pair |
  | Dev | `Standard_LRS` | Single-region dev (`ADR-008`); PSRule's replication rule is suppressed for LRS accounts only |

  Data protection is unchanged from Phase 0 (F7) on every account:
  - versioning;
  - 14-day blob and container soft delete;
  - change feed;
  - point-in-time restore for 13 days;
  - no shared keys, no public network access.

  **Warm-standby read path (prod only):**
  - The East US stamp has a private endpoint `<primary account>-secondary-pe` on the primary account's **read-only secondary** (`blob_secondary`). It is registered in the shared `privatelink.blob` zone as `<primary account>-secondary`.
  - The East US App Service identity holds **Storage Blob Data Reader** on the primary account's `def-blob` container: read only, never write (`modules/storageReaderAssignment.bicep`, deployed into the primary resource group).

  **Application Insights (`modules/appInsights.bicep`):**
  - One workspace-based component per region, `appi-defenstack-<env>-<region>`, storing telemetry in `log-defenstack-<env>` (`ADR-021`).
  - Key-based ingestion is **disabled**. The App Service identity sends telemetry with Entra ID, using **Monitoring Metrics Publisher** on its own component.
  - Public ingestion stays on until Phase 6 adds the Azure Monitor Private Link Scope.

  **App Service (`modules/appService.bicep`):**
  - App settings `APPLICATIONINSIGHTS_CONNECTION_STRING` and `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`.
  - `ipSecurityRestrictionsDefaultAction` and `scmIpSecurityRestrictionsDefaultAction` set to `Deny`, so the site and Kudu stay closed even if someone re-enables public network access.

  **Deploy-time secrets (`ADR-019`):**
  - Application secrets live in one GitHub **environment secret**, `KEYVAULT_SECRETS_JSON`: a JSON object of `{ "secret-name": "value" }`.
  - The `apply` job validates it with `scripts/ConvertTo-KeyVaultSecretsParameter.ps1` and passes it as the `@secure()` parameter `keyVaultSecrets`.
  - Azure Resource Manager writes the **same** values to **every** regional Key Vault, which is how the regional vaults stay in sync. The runner never needs a network path to the private vaults.
  - An empty or unset secret writes nothing.

  **Not in scope:**
  - AMPLS and private ingestion (Phase 6).
  - Recovery Services vaults and the failover procedure (Phase 8).
  - App code and its own use of the secrets.

  ## 2. Prerequisites

  - **Pipeline identity:** Phase 5 adds two delegatable roles, **Storage Blob Data Reader** (`2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`) and **Monitoring Metrics Publisher** (`3913510d-42f4-4e42-8a64-420c390055eb`). `scripts/New-GitHubDeploymentIdentity.ps1` now includes both by default. Re-apply the constrained assignment as described in §4 step 1. The identity's existing `Contributor` on each resource group covers writing Key Vault secrets through Azure Resource Manager (`Microsoft.KeyVault/vaults/secrets/write`).
  - **GitHub:** permission to create environment secrets on `dev` and `prod` (repository admin).
  - **Operator for §5–§6:** `Reader` on the resource groups. The Key Vault and Storage data-plane checks need:
    - the VPN or Bastion path from runbook 03, because both services are private;
    - `Key Vault Secrets User` (read) on the vault, PIM-eligible to the admin group (runbook 03 §2);
    - `Storage Blob Data Reader` (or `Contributor` for restores) on the container.
  - **Providers:** `Microsoft.Insights` (already registered for diagnostics) and `Microsoft.Storage`.
  - **Tools:** Azure CLI 2.90+ (the deploy combines a `.bicepparam` file with an extra `--parameters` value, which needs a current CLI), Bicep CLI 0.47.16, PowerShell 7 or 5.1.

  ## 3. Parameters

  | Name | Default | Prod value | Rationale |
  |---|---|---|---|
  | `keyVaultSecrets` (`main.bicep`, `@secure()`) | `{}` | from `KEYVAULT_SECRETS_JSON` | Application secrets for every regional vault. **Never** set it in a committed `.bicepparam` file (`tests/KeyVaultSecrets.Tests.ps1` enforces this) |
  | Storage SKU (`regionStamp.bicep`) | dev `Standard_LRS` | primary `Standard_RAGZRS`, standby `Standard_GRS` | §1 table (`ADR-020`) |
  | `blobSoftDeleteRetentionDays` (`storage.bicep`) | `14` | `14` | Soft delete for blobs and containers, plus change feed retention; point-in-time restore covers `retention - 1` days |
  | `applicationInsightsConnectionString` (`appService.bicep`) | set by the stamp | set by the stamp | The region's own component |
  | `primaryStorageAccountId` / `primaryStorageAccountName` (`regionStamp.bicep`) | `''` | set for the East US stamp only | Creates the warm-standby read endpoint |

  ## 4. Step-by-step deployment

  1. **Re-apply the pipeline identity's constrained role assignment,** so that it may assign the two new roles. Follow `docs/runbooks/00b-configure-pipeline-credentials.md` §8 "Assigning an extra role from Bicep", steps 2–3:
     1. Delete the existing RBAC Administrator assignment on each resource group.
     2. Re-run the script with its default role list.

     Check:

     ```powershell
     az role assignment list --assignee <pipeline-app-id> --resource-group rg-defenstack-dev-wus3 --role 'Role Based Access Control Administrator' --query '[0].condition' -o tsv
     ```

     Expected: the condition contains `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1` and `3913510d-42f4-4e42-8a64-420c390055eb`.

  2. **Create the environment secret** on each environment, even if empty for now: GitHub → **Settings** → **Environments** → `dev` → **Add environment secret** → name `KEYVAULT_SECRETS_JSON`, value `{}`. When the app needs secrets, set it to, for example, `{"api-key":"<value>","db-password":"<value>"}`. Do the same on `prod`. With the GitHub CLI:

     ```powershell
     gh secret set KEYVAULT_SECRETS_JSON --env dev --body '{}'
     ```

     Rules, enforced by the converter: names are 1–127 letters, digits or hyphens; values are non-empty strings.

  3. **Validate and preview**, from the repository root:

     ```powershell
     az deployment sub validate --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
     az deployment sub what-if --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
     ```

     Check the what-if:
     - In `rg-defenstack-dev-wus3`: **create** `appi-defenstack-dev-wus3` and a role assignment on it; **modify** the App Service (two app settings and two default-deny restrictions).
     - In prod, also: the primary storage account `sku.name` `Standard_GRS` → `Standard_RAGZRS`, and in `rg-defenstack-prod-eus` a new private endpoint `<primary account>-secondary-pe`, plus a role assignment in `rg-defenstack-prod-wus3`.
     - The plan job and what-if run without `KEYVAULT_SECRETS_JSON`, so they never show secret writes. That is expected.
     - **Stop** if the what-if shows any storage account or vault being recreated.

     Prod only: run the same `validate` with `params/prod.bicepparam` before the prod deployment. It is the first deployment of the RA-GZRS account with point-in-time restore (§9).
  4. **Deploy through the pipeline:** GitHub → Actions → `deploy` → **Run workflow** → `dev` (prod: the two-approval flow, `ADR-012`). Check that the step **Prepare Key Vault secrets** logs `Prepared <n> Key Vault secret(s): <names>` (names only, never values), and that **Deploy** succeeds.
  5. **Record the component names:** `az monitor app-insights component show -g rg-defenstack-dev-wus3 --app appi-defenstack-dev-wus3 --query "{name:name, workspace:workspaceResourceId, localAuth:disableLocalAuth}" -o json`. Expected: the workspace ID ends in `log-defenstack-dev`, and `"localAuth": true`, which means local auth is disabled.

  ## 5. Manual and post-deployment steps

  ### 5.1 Secret sync: add, rotate or remove a secret

  - **Add or rotate:**
    1. Update `KEYVAULT_SECRETS_JSON` on the environment with the **complete** object (GitHub stores it as one value). For example:

       ```powershell
       gh secret set KEYVAULT_SECRETS_JSON --env prod --body (Get-Content .\secrets.prod.json -Raw)
       ```

       Keep that file outside the repository, and delete it afterwards.
    2. Run the deploy workflow. Every regional vault gets a new **version** of each changed secret; consumers that read `latest` pick it up.
  - **Check that both regions match** (over the VPN):

    ```powershell
    foreach ($kv in '<kv-wus3>', '<kv-eus>') { az keyvault secret show --vault-name $kv --name api-key --query "{vault:'$kv', updated:attributes.updated}" -o tsv }
    ```

    Expected: both vaults show the same deployment's timestamp, within a few minutes of each other.
  - **Remove:** taking a name out of the JSON does **not** delete it from the vaults, because deployments are incremental. Delete it from each vault over the VPN: `az keyvault secret delete --vault-name <kv> --name <secret>`. Purge protection keeps it recoverable for 90 days.
  - **Never** put secret values in a `.bicepparam` file, a pipeline variable, a PR, or a command line that is logged.

  ### 5.2 Restore deleted or overwritten data

  The examples use the dev primary account `<st>` and container `def-blob`, run over the VPN with `--auth-mode login`. Shared keys are disabled, so every command authenticates with Entra ID.

  | What happened | Recover with | Command |
  |---|---|---|
  | A blob was deleted (within 14 days) | Soft delete | `az storage blob undelete --account-name <st> --container-name def-blob --name <blob> --auth-mode login` |
  | A blob was overwritten | Versioning: copy a previous version over the current one | `az storage blob list --account-name <st> --container-name def-blob --prefix <blob> --include v --auth-mode login --query "[].{version:versionId, modified:properties.lastModified}" -o table`, then `az storage blob copy start --account-name <st> --destination-container def-blob --destination-blob <blob> --source-uri "https://<st>.blob.core.windows.net/def-blob/<blob>?versionid=<versionId>" --auth-mode login` |
  | A container was deleted (within 14 days) | Container soft delete | `az storage container list --account-name <st> --include-deleted --auth-mode login --query "[?deleted].{name:name, version:version}" -o table`, then `az storage container restore --account-name <st> --name def-blob --deleted-version <version> --auth-mode login` |
  | Many blobs were corrupted at a known time (within 13 days) | Point-in-time restore | `az storage blob restore --account-name <st> --resource-group rg-defenstack-dev-wus3 --time-to-restore 2026-10-02T09:00:00Z`. With no `--blob-range` it restores every container in the account; `def-blob` is the only one. It runs as a long operation: writes fail until it finishes, so stop the app writing first |
  | A Key Vault secret was deleted (within 90 days) | Soft delete | `az keyvault secret recover --vault-name <kv> --name <secret>`, or redeploy, which re-creates it from `KEYVAULT_SECRETS_JSON` |
  | A whole Key Vault was deleted | Vault soft delete; purge protection blocks purging | `az keyvault recover --name <kv>`, then redeploy |

  ### 5.3 Reading the primary's data from East US (prod, during an incident)

  - The primary account's secondary endpoint `https://<primary account>-secondary.blob.core.windows.net` resolves, from the East US spoke, to the East US private endpoint IP. It is **read-only**.
  - Check how current the copy is:

    ```powershell
    az storage account show -n <primary account> -g rg-defenstack-prod-wus3 --expand geoReplicationStats --query "geoReplicationStats.{status:status, lastSync:lastSyncTime}" -o table
    ```

    Expected: `status` is `Live`, and `lastSync` is within about 15 minutes.
  - Writes in East US go to the East US account. Account failover, which makes East US writable for the primary account, belongs to the DR runbook (Phase 8).

  ## 6. Validation

  | Check | Command | Expected result |
  |---|---|---|
  | Storage SKU per stamp | `az storage account list -g rg-defenstack-<env>-<region> --query "[].{name:name, sku:sku.name}" -o table` | dev `Standard_LRS`; prod wus3 `Standard_RAGZRS`; prod eus `Standard_GRS` |
  | Data protection | `az storage account blob-service-properties show -n <st> -g <rg> --query "{versioning:isVersioningEnabled, softDelete:deleteRetentionPolicy.days, containerSoftDelete:containerDeleteRetentionPolicy.days, pitr:restorePolicy.days, changeFeed:changeFeed.enabled}" -o json` | `true`, `14`, `14`, `13`, `true` |
  | Geo-replication (prod) | §5.3 command | `Live`, recent `lastSync` |
  | Warm-standby read endpoint (prod) | `az network private-endpoint show -g rg-defenstack-prod-eus -n <primary account>-secondary-pe --query "{group:privateLinkServiceConnections[0].groupIds[0], state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o json` | `blob_secondary`, `Approved` |
  | Secondary name resolves privately (prod, from the East US jump host or VPN) | `nslookup <primary account>-secondary.blob.core.windows.net` | An address in `10.10.1.0/24` |
  | Warm-standby reader role (prod) | `az role assignment list --scope <primary account id>/blobServices/default/containers/def-blob --query "[?roleDefinitionName=='Storage Blob Data Reader'].principalId" -o tsv` | The East US App Service principal ID |
  | App Insights is workspace-based with key auth off | §4 step 5 command | Workspace `log-defenstack-<env>`, `"localAuth": true` |
  | App Service telemetry settings | `az webapp config appsettings list -n <app> -g <rg> --query "[?starts_with(name,'APPLICATIONINSIGHTS')].{name:name, value:value}" -o table` | Connection string present; `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` = `Authorization=AAD` |
  | Publisher role | `az role assignment list --scope $(az monitor app-insights component show -g <rg> --app appi-defenstack-<env>-<region> --query id -o tsv) --query "[].roleDefinitionName" -o tsv` | `Monitoring Metrics Publisher` |
  | Default-deny restrictions | `az webapp config access-restriction show -n <app> -g <rg> --query "{site:ipSecurityRestrictionsDefaultAction, scm:scmIpSecurityRestrictionsDefaultAction}" -o json` | `Deny`, `Deny` |
  | Telemetry arrives (after any request through Front Door, runbook 04 §6) | KQL in `log-defenstack-<env>`: `AppRequests \| where TimeGenerated > ago(1h) \| summarize count() by AppRoleName` | One row per region with traffic |
  | Secrets written (when `KEYVAULT_SECRETS_JSON` is non-empty) | §5.1 check | The same names in every regional vault |

  Paste every output into the Phase 5 PR (spec §6 definition of done).

  ## 7. Rollback

  - **Storage SKU:** an RA-GZRS → GRS change, done by reverting the commit and redeploying, is supported, but Azure converts redundancy asynchronously and it can take hours. Never go to LRS in prod.
  - **Warm-standby read endpoint and reader role:** reverting does not delete them, because deployments are incremental. Remove them by hand:
    - `az network private-endpoint delete -g rg-defenstack-prod-eus -n <primary account>-secondary-pe`
    - `az role assignment delete --assignee <eus app principal> --scope <container id> --role 'Storage Blob Data Reader'`
  - **App Insights:** reverting leaves the component and role in place, and the app settings point to it. Harmless. Delete the component with `az monitor app-insights component delete --app <name> -g <rg>`, after a redeploy without the settings.
  - **Secrets:** see §5.1 "Remove". Purge protection means a deleted secret's name stays reserved until it is purged after 90 days.
  - **Prod locks:** Key Vault and the spoke VNet are locked (`CanNotDelete`). Removing a private endpoint in the locked spoke may need the lock lifted first (`az lock list -g rg-defenstack-prod-eus --query "[].id" -o tsv`, then `az lock delete --ids <id>`); the next deployment recreates it.

  ## 8. Operations

  - **Secret rotation:** rotate at the source system, then §5.1 "Add or rotate". Record the rotation in the change log, never the value.
  - **Geo-replication health:** check `lastSyncTime` (§5.3) weekly. Phase 6 adds an alert on it.
  - **Telemetry:** start in the workspace (`AppRequests`, `AppExceptions`, `AppDependencies`), filtered by `AppRoleName` per region. The App Insights blade works too, because the components are workspace-based.
  - **Cost drivers** (`docs/cost.md` "Phase 5 delta"):
    - the RA-GZRS premium over GRS on the prod primary account, plus geo-replication data transfer;
    - one extra private endpoint (East US);
    - App Insights ingestion, billed as Log Analytics ingestion in the shared workspace.

  ## 9. Troubleshooting

  | Symptom / error text | Cause | Fix |
  |---|---|---|
  | Step **Prepare Key Vault secrets** fails with `Secret name '<x>' is invalid` / `must have a non-empty string value` / `not valid JSON` | `KEYVAULT_SECRETS_JSON` breaks the rules in §4 step 2 | Fix the secret in the environment; the message names the secret, never the value |
  | **Deploy** fails with `unrecognized arguments` or an error about combining a `.bicepparam` file with other parameters | Azure CLI too old to combine `--parameters <file>.bicepparam` with `--parameters name=value` | Use the CLI the workflow installs (GitHub's `ubuntu-latest` image); locally, upgrade the CLI (§2) |
  | **Deploy** fails writing `Microsoft.KeyVault/vaults/secrets` with `Forbidden` | The deploying identity lacks `Microsoft.KeyVault/vaults/secrets/write` on the vault's resource group | Check the pipeline identity's `Contributor` on the region resource group (runbook 00b §6) |
  | Prod **Deploy** rejects the storage update, for example a property combination not supported with `Standard_RAGZRS` (point-in-time restore or change feed) | A platform limit on RA-GZRS accounts that only the first prod deployment exercises | Record the exact error in the PR. Then either drop `restorePolicy` on the prod primary account (keep versioning and soft delete) or keep `Standard_GRS`, and update `ADR-020` |
  | `AppRequests` stays empty, or the app logs `401` from the ingestion endpoint | The App Service identity lacks Monitoring Metrics Publisher, or `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` is missing | Check the two §6 rows; redeploy |
  | `AuthorizationFailed ... roleAssignments/write` for Storage Blob Data Reader or Monitoring Metrics Publisher | §4 step 1 was skipped | Re-apply the constrained assignment (§4 step 1) |
  | `nslookup <account>-secondary...` returns a public IP in East US | The secondary endpoint's DNS record is missing, or the client does not use the firewall DNS proxy | Check the private endpoint's DNS zone group; check that the client is on the VPN or the spoke |
  | `az storage blob restore` fails with `point in time restore is not enabled` | The account was created without `restorePolicy` (an older commit) | Redeploy; restore points start from when the policy was enabled |
  ````

- [ ] **Step 4: Create the ADRs**

  Create `docs/decisions/ADR-019-deploy-time-key-vault-secrets.md`:

  ```markdown
  # ADR-019: Regional Key Vaults are kept in sync by deploy-time secrets written through Azure Resource Manager

  ## Context
  The spec (§3) asks for "a regional Key Vault per stamp, synced by the pipeline". Every vault has `publicNetworkAccess: 'Disabled'` and is reachable only through its private endpoint. GitHub-hosted runners run on the public internet, so a pipeline step that calls the Key Vault data plane (`az keyvault secret set`) cannot reach any vault. The alternatives each had a cost:
  - a self-hosted runner inside the VNet, which is new infrastructure to patch and secure;
  - copying from the primary vault to the standby vault, which needs a data-plane path to both;
  - temporarily allowing public access, which defeats the design.

  No application secrets exist yet; there is no app code.

  ## Decision
  - Secrets live in one GitHub **environment secret** per environment, `KEYVAULT_SECRETS_JSON`, a JSON object of `{ "secret-name": "value" }`.
  - `deploy.yml`'s `apply` job validates it with `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`. The rules: names are 1–127 letters, digits or hyphens; values are non-empty strings; nothing is ever printed except names. The job then passes the result to `az deployment sub create` as the `@secure()` object parameter `keyVaultSecrets`. The temporary file is removed with `if: always()`.
  - `main.bicep` passes the same object to every stamp, and `modules/keyVault.bicep` creates one `Microsoft.KeyVault/vaults/secrets` resource per entry. Azure Resource Manager writes them through the control plane, so the runner never needs a network path to a vault. Every regional vault therefore receives the same values in the same deployment. That deployment is the sync.
  - An empty or unset secret writes nothing. The plan job (validate and what-if) runs without the secret and never shows secret writes.
  - Committed `.bicepparam` files must never set `keyVaultSecrets` (`tests/KeyVaultSecrets.Tests.ps1`).
  - The user chose this option when Phase 5 was planned.

  ## Consequences
  - The pipeline needs no data-plane role on the vaults. Its existing `Contributor` on each region resource group covers `Microsoft.KeyVault/vaults/secrets/write`.
  - Anyone who can edit the environment secret, or run the deploy job, controls the secret values. The prod environment's required reviewers and two-approval flow (`ADR-012`) gate prod.
  - Removing a name from the JSON does not delete the secret: deployments are incremental. Deletion is a manual, per-vault step (runbook 05 §5.1).
  - Every deployment writes a new version of each secret, even when the value is unchanged. Consumers must read `latest`, not a pinned version.
  - Writing secrets through Azure Resource Manager to a private, RBAC-mode vault is verified by the first dev deployment with a non-empty secret (runbook 05 §6 and §9).

  ## Revisit when
  The app needs secrets that rotate outside deployments (for example, generated credentials), or a self-hosted runner in the VNet exists for other reasons.
  ```

  Create `docs/decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md`:

  ```markdown
  # ADR-020: Prod primary storage is RA-GZRS; the warm standby reads it through the secondary endpoint

  ## Context
  The spec (§3) asks for prod storage on **RA-GZRS**, geo-copied to East US, consumed by the DR stamp "through a private endpoint on the secondary endpoint (`blob-secondary` group ID)". Until Phase 5, every prod account was `Standard_GRS`, and PSRule's `Azure.Storage.UseReplication` rule was excluded globally until "Phase 5: storage moves to RA-GZRS". Each region also has its own account for its own state.

  ## Decision
  - **SKU per stamp** (`modules/regionStamp.bicep`):
    - prod primary: `Standard_RAGZRS` (zone-redundant in West US 3, read access to the East US copy);
    - prod warm standby: `Standard_GRS` (its own state, geo-copied to its pair);
    - dev: `Standard_LRS` (`ADR-008`).
  - **Read path:** the East US stamp creates a private endpoint on the primary account's `blob_secondary` sub-resource (`modules/storageSecondaryEndpoint.bicep`), registered in the shared `privatelink.blob` zone as `<account>-secondary`. It exists only when `main.bicep` passes the primary account to the secondary stamp, which happens only with `deploySecondaryRegion`.
  - **Least privilege:** the East US App Service identity gets **Storage Blob Data Reader**, never a write role, on the primary `def-blob` container (`modules/storageReaderAssignment.bicep`, deployed into the primary resource group). The pipeline identity may now delegate that role (runbook 00b).
  - **PSRule:** the global `Azure.Storage.UseReplication` exclusion is removed. The rule is suppressed only for `Standard_LRS` accounts (`DefenStack.DevLocallyRedundantStorage`, matched on `sku.name`, because storage names are hashed).
  - Data protection from Phase 0 (F7) stays on every account: versioning, soft delete, change feed and point-in-time restore.

  ## Consequences
  - In a West US 3 outage, the warm standby can read the primary's data up to the last geo-sync (typically under 15 minutes old) without any failover. Writes during the outage go to the East US account until a customer-managed account failover, which Phase 8 covers.
  - The RA-GZRS premium and geo-replication transfer apply to the prod primary account only (`docs/cost.md` "Phase 5 delta").
  - A PSRule failure on any future non-LRS account without replication is no longer hidden by a global exclusion.
  - Combining RA-GZRS with point-in-time restore and change feed is first exercised by the prod deployment. If Azure rejects the combination, runbook 05 §9 says what to change and requires this ADR to be updated.

  ## Revisit when
  Phase 8 designs account failover, or the application needs writable storage in East US during normal operation.
  ```

  Create `docs/decisions/ADR-021-application-insights-per-region.md`:

  ```markdown
  # ADR-021: One workspace-based Application Insights component per region, Entra ID ingestion only

  ## Context
  The spec (§3) asks for workspace-based Application Insights, ingesting through AMPLS. AMPLS arrives in Phase 6. Telemetry could go to one global component or to one component per region.

  ## Decision
  - **One component per region**, `appi-defenstack-<env>-<region>` (`modules/appInsights.bicep`), in the region's resource group. Each is workspace-based on the shared `log-defenstack-<env>` workspace. The user chose this when Phase 5 was planned.
  - **Key-based ingestion is disabled** (`DisableLocalAuth: true`). Each App Service sends telemetry with its managed identity:
    - app settings `APPLICATIONINSIGHTS_CONNECTION_STRING` and `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`;
    - the **Monitoring Metrics Publisher** role on its own component only (`modules/appInsightsPublisher.bicep`), which the pipeline identity may now delegate.
  - **Public ingestion and query stay enabled** until Phase 6 adds the Azure Monitor Private Link Scope.

  ## Consequences
  - A regional outage takes only that region's component with it. All telemetry still lands in the one workspace, so a cross-region query is a single KQL query filtered by `AppRoleName`.
  - A leaked connection string cannot be used to inject telemetry, because ingestion requires an Entra token for an identity with the publisher role.
  - Until Phase 6, telemetry leaves the VNet over the public ingestion endpoint, authenticated with Entra ID. The firewall's AzureMonitor rule already allows it from the spoke.
  - Telemetry costs are Log Analytics ingestion in the shared workspace; there is no separate App Insights bill.

  ## Revisit when
  Phase 6 adds AMPLS. Set both public network access flags to `Disabled` then.
  ```

- [ ] **Step 5: Update the existing documents**

  Each edit below is an exact find/replace, and the find text occurs once in the file. If a find text is not found, stop and report. Change nothing outside the find text. These files contain non-ASCII characters (—, →, ↔, §), so read and write them as UTF-8.

  **`docs/architecture/overview.md`, edit 1 of 7.** Find:

  ```markdown
  # Architecture overview: Phase 1-4 (subscription-scope, multi-region, Premium firewall, admin access, public ingress)
  ```

  Replace with:

  ```markdown
  # Architecture overview: Phase 1-5 (subscription-scope, multi-region, Premium firewall, admin access, public ingress, app and data resilience)
  ```

  **`docs/architecture/overview.md`, edit 2 of 7.** Find:

  ```markdown
  What later phases add (not present after Phase 4):

  | Phase | Adds |
  |---|---|
  | 5 | RA-GZRS storage, Application Insights |
  ```

  Replace with:

  ```markdown
  **Phase 5** added app and data resilience:
  - The prod primary storage account is RA-GZRS. The East US warm standby reads it through a private endpoint on its read-only secondary, as Storage Blob Data Reader (`ADR-020`).
  - Each region has a workspace-based Application Insights component that accepts Entra ID ingestion only (`ADR-021`).
  - App Service public access restrictions default to deny.
  - Application secrets come from the `KEYVAULT_SECRETS_JSON` environment secret and are written to every regional Key Vault through Azure Resource Manager (`ADR-019`).

  See [runbook 05](../runbooks/05-app-and-data.md).

  What later phases add (not present after Phase 5):

  | Phase | Adds |
  |---|---|
  ```

  **`docs/architecture/overview.md`, edit 3 of 7.** Find:

  ```markdown
  | Front Door origin | `app-<regionCode>` | `app-wus3` |
  ```

  Replace with:

  ```markdown
  | Front Door origin | `app-<regionCode>` | `app-wus3` |
  | `names.appInsights` | `appi-defenstack-<env>-<regionCode>` | `appi-defenstack-dev-wus3` |
  | Warm-standby read endpoint (prod East US) | `<primary storage account>-secondary-pe` | `stwus3<hash>-secondary-pe` |
  ```

  **`docs/architecture/overview.md`, edit 4 of 7.** Find:

  ```markdown
  Storage account (`Standard_LRS`) with private endpoint
  ```

  Replace with:

  ```markdown
  Storage account (`Standard_LRS`) with private endpoint; Application Insights `appi-defenstack-dev-wus3` (workspace-based, Entra ID ingestion only)
  ```

  **`docs/architecture/overview.md`, edit 5 of 7.** Find:

  ```markdown
  -wus3` zone-redundant, 3 instances (`isProd && isPrimary`); Storage account `Standard_GRS`;
  ```

  Replace with:

  ```markdown
  -wus3` zone-redundant, 3 instances (`isProd && isPrimary`); Storage account `Standard_RAGZRS` (`ADR-020`), with a Storage Blob Data Reader assignment on `def-blob` for the East US App Service;
  ```

  **`docs/architecture/overview.md`, edit 6 of 7.** Find:

  ```markdown
  stance, non-zonal (no scale-out until failover, `ADR-008`); Storage account `Standard_GRS`;
  ```

  Replace with:

  ```markdown
  stance, non-zonal (no scale-out until failover, `ADR-008`); Storage account `Standard_GRS`; private endpoint `<primary account>-secondary-pe` on the primary account's read-only secondary (`blob_secondary`);
  ```

  **`docs/architecture/overview.md`, edit 7 of 7.** Find:

  ```markdown
  - [ADR-018: Front Door deploys from main.bicep after the stamps; the pipeline approves its Private Link connections](../decisions/ADR-018-front-door-placement-and-private-link-approval.md)
  ```

  Replace with:

  ```markdown
  - [ADR-018: Front Door deploys from main.bicep after the stamps; the pipeline approves its Private Link connections](../decisions/ADR-018-front-door-placement-and-private-link-approval.md)
  - [ADR-019: Regional Key Vaults are kept in sync by deploy-time secrets written through Azure Resource Manager](../decisions/ADR-019-deploy-time-key-vault-secrets.md)
  - [ADR-020: Prod primary storage is RA-GZRS; the warm standby reads it through the secondary endpoint](../decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md)
  - [ADR-021: One workspace-based Application Insights component per region, Entra ID ingestion only](../decisions/ADR-021-application-insights-per-region.md)
  ```

  **`docs/cost.md`, edit 1 of 1.** Find:

  ```markdown
  ## Dominant future cost drivers
  ```

  Replace with:

  ```markdown
  ## Phase 5 delta
  Phase 5 changes the prod primary storage SKU and adds one Application
  Insights component per region. As with every phase, **fill in the actual
  dollar estimate from the Pricing Calculator; do not invent prices.**

  | Environment | Cost driver | What changed / why it costs more |
  |---|---|---|
  | Prod | Primary storage account `Standard_GRS` → `Standard_RAGZRS` | The RA-GZRS per-GB rate is higher than GRS's, and geo-replication data transfer to East US is billed per GB (`ADR-020`) |
  | Prod | Private endpoint `<primary account>-secondary-pe` in East US | One more private endpoint: hourly, plus per-GB processed |
  | Both | Application Insights ×1 per deployed region | No separate charge for workspace-based components. Telemetry is billed as Log Analytics ingestion in `log-defenstack-<env>` (`ADR-021`); measure with the `Usage` KQL pattern on the `App*` tables |
  | Both | Key Vault secret operations | Each deployment with a non-empty `KEYVAULT_SECRETS_JSON` writes one version per secret per vault, billed per 10,000 operations; negligible |
  | Dev | No storage change | Dev stays `Standard_LRS` (`ADR-008`) |

  **Estimate:** fill in from the Pricing Calculator (Storage: Block blob,
  RA-GZRS vs GRS, measured capacity plus geo-replication GB; Private Link: one
  endpoint; Log Analytics: the measured `App*` ingestion from a week of dev
  traffic).

  ## Dominant future cost drivers
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 1 of 2.** Find:

  ```markdown
  `Virtual Machine Administrator Login` (`1c0163c0-47e6-4577-8991-ea5c82e286e4`, Phase 3: admin group on the jump host) | RBAC Administrator condition | No |
  ```

  Replace with:

  ```markdown
  `Virtual Machine Administrator Login` (`1c0163c0-47e6-4577-8991-ea5c82e286e4`, Phase 3: admin group on the jump host); `Storage Blob Data Reader` (`2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`, Phase 5: warm-standby app on the primary container); `Monitoring Metrics Publisher` (`3913510d-42f4-4e42-8a64-420c390055eb`, Phase 5: App Service identity on its App Insights component) | RBAC Administrator condition | No |
  | `KEYVAULT_SECRETS_JSON` | `{}` until the app has secrets | GitHub **environment secret** on `dev` and `prod`, read only by the `apply` job (runbook 05 §5.1, `ADR-019`) | **Yes**: create it as a secret, never a variable |
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 2 of 2.** Find:

  ```markdown
  Phase 3 did this for `Virtual Machine Administrator Login`, which is now in the script's default list, so an identity created before Phase 3 needs only steps 2–3 (runbook 03 §4 step 3):
  ```

  Replace with:

  ```markdown
  Phase 3 did this for `Virtual Machine Administrator Login`, and Phase 5 for `Storage Blob Data Reader` and `Monitoring Metrics Publisher`. All three are in the script's default list, so an identity created before Phase 5 needs only steps 2–3 (runbook 03 §4 step 3, runbook 05 §4 step 1):
  ```

  **`docs/runbooks/00-pipeline-and-identity.md`, edit 1 of 1.** Find:

  ```markdown
  | `-DelegatableRoleDefinitionIds` | Storage Blob Data Contributor, Virtual Machine Administrator Login (Phase 3) | extended per phase |
  ```

  Replace with:

  ```markdown
  | `-DelegatableRoleDefinitionIds` | Storage Blob Data Contributor, Virtual Machine Administrator Login (Phase 3), Storage Blob Data Reader and Monitoring Metrics Publisher (Phase 5) | extended per phase |
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 1 of 1.** Find:

  ```markdown
  | `customDomainHostName` | `''` | `''` | `''` until the domain exists | Front Door custom domain at the external DNS host ([runbook 04](04-ingress.md) §5.1) |
  ```

  Replace with:

  ```markdown
  | `customDomainHostName` | `''` | `''` | `''` until the domain exists | Front Door custom domain at the external DNS host ([runbook 04](04-ingress.md) §5.1) |
  | `keyVaultSecrets` (`@secure()`) | `{}` | from `KEYVAULT_SECRETS_JSON` | from `KEYVAULT_SECRETS_JSON` | Never set in a parameter file; the pipeline supplies it ([runbook 05](05-app-and-data.md) §5.1) |
  ```

  **`docs/runbooks/04-ingress.md`, edit 1 of 1.** Find:

  ```markdown
  | Pipeline step fails with `multiple pending connections share the request message` |
  ```

  Replace with:

  ```markdown
  | Pipeline step fails with `... but no Front Door origin in <profile>/app references this App Service, so it cannot be Front Door's request` | A request carries Front Door's message, but no origin points at this app. Front Door creates its origin before it sends the request, so this request is not Front Door's (Phase 5) | §5.2 step 1: reject the request, raise an incident. If the origin really is missing, redeploy first |
  | Pipeline step fails with `multiple pending connections share the request message` |
  ```

  **`README.md`, edit 1 of 1.** Find:

  ```markdown
  and `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover)
  ```

  Replace with:

  ```markdown
  `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover), and `05-app-and-data.md` (storage resilience, Application Insights, deploy-time Key Vault secrets, restore procedures)
  ```

- [ ] **Step 6: Run the full suite**

  The full suite should show `Tests Passed: 383, Failed: 0`. Encoding check: `grep -rln $'\xEF\xBF\xBD' docs README.md --exclude-dir=superpowers` prints nothing.

- [ ] **Step 7: Commit**

  ```bash
  git add docs/runbooks/05-app-and-data.md docs/decisions/ADR-019-deploy-time-key-vault-secrets.md docs/decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md docs/decisions/ADR-021-application-insights-per-region.md docs/architecture/overview.md docs/cost.md docs/runbooks/00b-configure-pipeline-credentials.md docs/runbooks/00-pipeline-and-identity.md docs/runbooks/01-deploy-stack.md docs/runbooks/04-ingress.md README.md tests/Docs.Tests.ps1
  git commit -m "docs: runbook 05 app and data, ADR-019/020/021, and Phase 5 documentation updates" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

## After the last task (human, not the implementer)

A person follows only runbook 05:

1. In dev: §4 steps 1–5 (re-apply the identity assignment, create `KEYVAULT_SECRETS_JSON` with one test secret, validate, what-if, deploy), then every §6 row. Paste the outputs into the PR.
2. Before prod: `az deployment sub validate` with `params/prod.bicepparam`. This is Review Focus 1, the RA-GZRS combination. After the prod deployment, run the §6 prod rows: the geo-replication status, the secondary endpoint, and the reader role.

