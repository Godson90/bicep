# 07 - Governance and posture runbook (Defender for Cloud, Azure Policy, exemptions, just-in-time access)

> Owning module(s): `governance.bicep` (subscription scope, operator-deployed) with `params/governance.bicepparam`, and `modules/governance/defenderPlans.bicep`, `securityContacts.bicep`, `policies.bicep`, `flowLogStorageExemption.bicep`, `legacyWaiver.bicep`, `jitRequesterRole.bicep`, `jitRequesterAssignment.bicep`. Pipeline side (deployed by `deploy.yml`): `modules/virtualMachine.bicep` (JIT policy and NIC NSG) and `modules/spokeNetwork.bicep` (`management` NSG). Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Governance and posture" and "Management jump host" (JIT), §5 Phase 7. Decisions: `ADR-026`, `ADR-027`, `ADR-028`, `ADR-029`.

## 1. Purpose and scope

This runbook turns on Microsoft Defender for Cloud and Azure Policy for the subscription, and puts the jump host behind just-in-time (JIT) access. **An operator deploys `governance.bicep` by hand. `main.bicep` and the pipeline never do**, so the pipeline identity cannot change policy assignments, definitions or exemptions, the subscription's Defender plans, the security contact or the JIT Requester role (`ADR-026`). Its resource-group `Contributor` can still set per-resource Defender overrides (for example a storage account's `defenderForStorageSettings`) and initiate JIT requests in its own groups. One `governance.bicepparam` covers one subscription: when dev and prod share a subscription, it covers both.

**Defender for Cloud (`ADR-026`), at subscription scope:**

| Plan (`Microsoft.Security/pricings`) | Tier and settings |
|---|---|
| `VirtualMachines` (Defender for Servers) | Standard, sub-plan `P2`, extension `AgentlessVmScanning`. JIT needs this plan. No `MdeDesignatedSubscription` (that is for directly onboarded non-Azure machines) |
| `AppServices` | Standard |
| `StorageAccounts` | Standard, sub-plan `DefenderForStorageV2`, `OnUploadMalwareScanning` with a cap of `malwareScanCapGbPerMonth` GB per account per month, and `SensitiveDataDiscovery` |
| `KeyVaults`, `Arm`, `CloudPosture` (Defender CSPM) | Standard, Azure's default sub-plan and extensions |

The plans are updated one at a time (`@batchSize(1)`), because parallel pricing updates conflict. The security contact `default` emails the `SECURITY_CONTACT_EMAILS` addresses and the subscription Owners for alerts of severity High. The retired agent auto-provisioning setting is not managed: agentless scanning and the default Defender for Endpoint integration replace it.

Each flow-log account `stfl…` overrides the subscription's Storage settings (`defenderForStorageSettings/current`): Defender for Storage and its activity monitoring stay on, but on-upload malware scanning and sensitive data discovery are off. Only Network Watcher's identity writes there, and scanning would rescan each hourly flow-log blob on every block commit (`ADR-026`).

**Day-one effects:**
- Servers P2 bills, scans and deploys Defender for Endpoint (`MDE.Linux` / `MDE.Windows`) onto **every existing VM** in the subscription, including the legacy `defenStack` group's.
- The security contact PUT replaces any existing `default` contact. §4 step 5 reads it first and merges its addresses.

**Azure Policy (`ADR-027`), at subscription scope. Every assignment name starts with `defenstack-`:**

| Assignment | Policy | Effect | Enforcement |
|---|---|---|---|
| `defenstack-mcsb` | Microsoft cloud security benchmark initiative | Its members' defaults (mostly audit) | `Default` |
| `defenstack-deny-storage-public-network`, `-key-vault-`, `-app-`, `-app-slot-`, `-function-`, `-function-slot-public-network` | "… should disable public network access" (6 built-ins) | `Deny` | `denyEnforcement` |
| `defenstack-allowed-locations` | Allowed locations: `westus3`, `eastus`, `global` | Deny (fixed) | `denyEnforcement` |
| `defenstack-allowed-resource-group-locations` | Allowed locations for resource groups: `westus3`, `eastus` | Deny; assigned without an `effect` parameter (unverified, §9) | `denyEnforcement` |
| `defenstack-deny-public-ip` | Custom `defenstack-deny-public-ip-except-allowlist`: public IPs whose name is not in the allowlist | `deny` | `denyEnforcement` |
| `defenstack-audit-diagnostic-settings` | Audit diagnostic setting for selected resource types (firewalls, Bastion, VPN gateways, Front Door, Key Vault, App Service, blob services) | `AuditIfNotExists` | `Default` |

**Audit-first.** `denyEnforcement` defaults to `DoNotEnforce`: Azure evaluates and reports every deny assignment, but blocks nothing. After a clean compliance review it becomes `Default` (§5.2).

The public IP allowlist is computed from the naming convention: `pip-afw-…`, `pip-bas-…`, `pip-vpng-…-1` and `-2` for every environment and region in `environments` / `environmentRegions`, 12 names by default. It includes the warm standby's admin-access IPs, so a failover is never blocked.

**Exemptions (`ADR-027`, `ADR-029`):**

| Exemption | Scope | Assignment | Category |
|---|---|---|---|
| `defenstack-flow-log-storage-public-network` | Each flow-log account `stfl<region><suffix>` | Storage public network access | `Mitigated`, no expiry: a deny-all firewall with the trusted-services bypass replaces disabled public access (`ADR-023`) |
| `defenstack-legacy-waiver-<assignment without its defenstack- prefix>` (9, for example `defenstack-legacy-waiver-deny-public-ip`) | The legacy resource group `legacyResourceGroupName` (`defenStack`) | Every deny assignment | `Waiver`, expiring at the end of `legacyWaiverExpiresOn` (UTC), until runbook 01a tears the group down |

**JIT access (`ADR-028`):**

| Piece | Where | Deployed by |
|---|---|---|
| Custom role **DefenStack JIT Requester** (read and initiate JIT, read the VM and its NIC) | Subscription, assignable there only | `governance.bicep` |
| Its assignment to the environment's admin group (`adminGroupObjectIds.<env>`) | The environment's **primary** resource group (`rg-defenstack-<env>-wus3`), where the jump host runs | `governance.bicep` |
| JIT policy `default` (`Microsoft.Security/locations/jitNetworkAccessPolicies`, kind Basic) for the jump host: TCP 22 and 3389, sources the Bastion subnet, the VPN pool and any ADR-approved management sources (`managementSourceCidrs`), at most 3 hours (`PT3H`) | The jump host's resource group and region | The pipeline (`deploy.yml`), with the jump host |
| NIC NSG `<vm>-nsg`: `deny-ssh-rdp-inbound` (priority 4000, any source) replaces the static allow | The jump host's NIC | The pipeline |
| `management` NSG: `allow-management-ssh-rdp` (priority 100) from the Bastion subnet and the VPN pool, **unchanged** | The `management` subnet | The pipeline |

SSH and RDP to the jump host are **closed unless JIT-granted, and reachable when granted**. The subnet NSG keeps the outer bound (only Bastion and VPN clients can ever connect). The NIC NSG denies both ports. A granted request makes Defender for Cloud add a time-bound allow above that deny, on the NSG closest to the VM, so the session passes both NSGs.

**Not in scope:**
- `DeployIfNotExists` diagnostic settings and any policy remediation (the spec's DINE item is replaced by an audit, `ADR-027`).
- Defender for Cloud settings outside the plans and the contact (for example the `WDATP` integration toggle).
- Resource locks: they came with Phases 1–6 in the workload templates.

## 2. Prerequisites

- **Operator roles, activated through PIM** at subscription scope, for §4 only. `governance.bicep` writes Defender pricings and the security contact, policy definitions, assignments and exemptions, a custom role definition and role assignments. The minimal pair is:
  - **Security Admin**: `Microsoft.Security/*` (pricings, security contact), `Microsoft.Authorization/policyAssignments/*`, `policyDefinitions/*`, `policyExemptions/*` and `Microsoft.Resources/deployments/*`;
  - **User Access Administrator**: `Microsoft.Authorization/roleDefinitions/write` for **DefenStack JIT Requester**, `Microsoft.Authorization/roleAssignments/write` for its assignments, and `*/read` (the flow-log exemptions read their storage accounts).

  If ARM refuses a policy write under that pair, add **Resource Policy Contributor**. **Owner** alone covers everything, and is the fallback when the tenant does not offer the narrower roles as PIM-eligible. Activate: Entra admin center → **Identity Governance** → **Privileged Identity Management** → **My roles** → **Azure resources** → the subscription → **Activate** each role, with a justification naming this runbook. Deactivate them after §4.
- **Pipeline identity:** unchanged. It already holds `Contributor` on each regional resource group, which includes `Microsoft.Security/locations/jitNetworkAccessPolicies/write`, so `deploy.yml` creates the JIT policy with no new grant (`ADR-028`). Do not re-run the identity script for Phase 7.
- **Everything governance targets must exist** (§5.3, "the ordering trap"): each regional resource group in `environments` / `environmentRegions` (default `rg-defenstack-dev-wus3`, `rg-defenstack-prod-wus3`, `rg-defenstack-prod-eus`) and its Phase 6 flow-log account `stfl…`; and the legacy resource group `defenStack`, or `legacyResourceGroupName = ''`.
- **Providers:**

  ```powershell
  foreach ($ns in 'Microsoft.Security','Microsoft.PolicyInsights','Microsoft.Authorization') { az provider register --namespace $ns }
  foreach ($ns in 'Microsoft.Security','Microsoft.PolicyInsights','Microsoft.Authorization') { az provider show -n $ns --query registrationState -o tsv }
  ```

  Expect `Registered` three times.
- **Admin groups:** the Entra groups from runbook 03 §4 step 1 (`sg-defenstack-<env>-admins`), with PIM-eligible membership (runbook 03 §5.5).
- **Tools:** Azure CLI 2.90+, Bicep CLI 0.47.16, PowerShell 7 or 5.1. No network path is needed for §4; §5.4 (connecting after a JIT grant) needs the VPN or Bastion from runbook 03.

## 3. Parameters

`governance.bicep`, set in `params/governance.bicepparam`:

| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `securityContactEmails` | none (at least one) | from `SECURITY_CONTACT_EMAILS` | The parameter file reads the environment variable (semicolon-separated); addresses are never committed. Unset gives an empty list, which ARM refuses |
| `malwareScanCapGbPerMonth` | `5000` | `5000` | GB scanned per storage account per month; `-1` removes the cap. Billed per GB scanned (`docs/cost.md` "Phase 7 delta") |
| `denyEnforcement` | `DoNotEnforce` | `DoNotEnforce`, then `Default` after §5.2 | Audit-first for every deny assignment (`ADR-027`) |
| `environments` | `['dev','prod']` | `['dev','prod']` | Environments in this subscription. Their public IPs are allowed, flow-log accounts exempted and admin groups granted JIT requests |
| `environmentRegions` | `{ dev: ['westus3'], prod: ['westus3','eastus'] }` | same | Regions per environment, primary first. Mirrors the parameter files: dev `deploySecondaryRegion = false`, prod `true` (a test pins it). Every listed stamp must already exist |
| `adminGroupObjectIds` | `{ dev: '', prod: '' }` | the two admin group object IDs | Must equal `adminGroupObjectId` in `params/dev.bicepparam` and `params/prod.bicepparam` (a test pins it). Empty skips that environment's JIT Requester assignment |
| `legacyResourceGroupName` | `defenStack` | `defenStack`, then `''` | The legacy group waived from the deny assignments. Set `''` once runbook 01a has deleted it |
| `legacyWaiverExpiresOn` | none (required) | `2027-03-31` | `yyyy-MM-dd`, end of that day UTC. **`2027-03-31` is a placeholder: confirm it** with the runbook 01a teardown date |

Pipeline side (`modules/virtualMachine.bicep`, fixed in code): JIT ports `22`, `3389` (TCP), `maxRequestAccessDuration` `PT3H`, sources = `managementSourceCidrs` as `regionStamp.bicep` derives it (Bastion subnet, VPN pool and any extra approved range). NIC deny priority `4000`.

## 4. Step-by-step deployment

Run from the repository root. **Order matters: governance first, then the workload deploy.** The JIT policy needs Defender for Servers, which only `governance.bicep` turns on.

1. **Activate the operator roles through PIM** (§2, first bullet), then sign in and select the subscription:

   ```powershell
   az login
   az account set --subscription <subscription id>
   az role assignment list --assignee (az ad signed-in-user show --query id -o tsv) --scope /subscriptions/<subscription id> --include-groups --query "[].roleDefinitionName" -o tsv
   ```

   Check: `Security Admin` and `User Access Administrator` (or `Owner`) are listed.

2. **Register the providers** (§2).

3. **Check the targets exist** (§5.3):

   ```powershell
   foreach ($rg in 'rg-defenstack-dev-wus3','rg-defenstack-prod-wus3','rg-defenstack-prod-eus','defenStack') { "$rg $(az group exists --name $rg)" }
   az storage account list --query "[?starts_with(name,'stfl')].{name:name, rg:resourceGroup}" -o table
   ```

   Expected: `true` for every group listed in your parameters, and one `stfl…` account per regional group. A missing regional group or account: deploy that workload first, or narrow `environments` / `environmentRegions`. A missing `defenStack`: set `legacyResourceGroupName = ''`.

4. **Fill in the admin groups** in `params/governance.bicepparam`, from the environment parameter files (runbook 03 §4 step 1), and commit the change through a pull request:

   ```bicep
   param adminGroupObjectIds = {
     dev: '<dev admin group object ID>'
     prod: '<prod admin group object ID>'
   }
   ```

5. **Set `SECURITY_CONTACT_EMAILS`** in the same PowerShell session, before `what-if` or `create`. Use monitored team mailboxes. The deploy replaces the subscription's `default` contact, so read it first:

   ```powershell
   az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Security/securityContacts/default?api-version=2023-12-01-preview"
   ```

   Merge any addresses in its `properties.emails` into the variable (`NotFound` means there is no contact yet):

   ```powershell
   $env:SECURITY_CONTACT_EMAILS = 'secops@example.org;cloud-admins@example.org'
   bicep build-params params/governance.bicepparam --stdout | ConvertFrom-Json | ForEach-Object { ($_.parametersJson | ConvertFrom-Json).parameters.securityContactEmails.value }
   ```

   Check: each address is printed on its own line. Empty output means the variable is not set in this session.

6. **Validate and preview:**

   ```powershell
   az deployment sub validate --location westus3 --name defenstack-governance --template-file governance.bicep --parameters params/governance.bicepparam
   az deployment sub what-if --location westus3 --name defenstack-governance --template-file governance.bicep --parameters params/governance.bicepparam
   ```

   The `using` line already binds the template, so `--template-file` is optional with Azure CLI 2.53+. Check the what-if:
   - Subscription: **create** or **modify** 6 `Microsoft.Security/pricings` (the free tier already exists, so these usually show as modify), `securityContacts/default`, the definition `defenstack-deny-public-ip-except-allowlist`, the 11 `defenstack-*` assignments and the role definition `DefenStack JIT Requester`. Every deny assignment shows `enforcementMode: DoNotEnforce`.
   - `rg-defenstack-<env>-<region>`: **create** `defenstack-flow-log-storage-public-network` on each `stfl…` account; in the primary groups, one role assignment per admin group that is set.
   - `defenStack`: **create** 9 `defenstack-legacy-waiver-*` exemptions.
   - **Stop** on any delete, and on any assignment whose `enforcementMode` is `Default` when you did not intend the §5.2 switch.

7. **Deploy:**

   ```powershell
   az deployment sub create --location westus3 --name defenstack-governance --template-file governance.bicep --parameters params/governance.bicepparam
   ```

   Expected: `provisioningState` `Succeeded`, and outputs `defenderPlanNames` (6 names), `allowedPublicIpNames` (12 by default) and `jitRequesterRoleDefinitionId`. The plans update one after another, so allow about 10 minutes.

8. **Deploy the workload** through the pipeline: GitHub → Actions → `deploy` → **Run workflow** → `dev`, then prod (two approvals, `ADR-012`). The jump host's environment (`enableVirtualMachine = true`) gets the JIT policy and the NIC deny. Check the what-if: **modify** `<vm>-nsg` (rule `allow-management-ssh-rdp` removed, `deny-ssh-rdp-inbound` added) and **create** `Microsoft.Security/locations/westus3/jitNetworkAccessPolicies/default`. `<spoke VNet>-management-nsg` must **not** change. From now on, an admin needs a JIT request before every session (§5.4, runbook 03).

9. **Make the admin groups' memberships PIM-eligible**, if they are not already (runbook 03 §5.5). One activation gives both `Virtual Machine Administrator Login` and **DefenStack JIT Requester**.

10. **Start the audit week** (§5.2).

## 5. Manual and post-deployment steps

### 5.1 Defender recommendation handling

Review once a week, and after every phase deploy: **Defender for Cloud** → **Recommendations**, filtered to this subscription.

```powershell
az security assessment list --query "[?status.code=='Unhealthy'].{recommendation:displayName, resource:resourceDetails.Id, severity:metadata.severity}" -o table
az security alert list --query "[?status=='Active'].{alert:alertDisplayName, severity:severity, resource:compromisedEntity}" -o table
```

Triage each unhealthy recommendation:
1. **Fix it in Bicep** when the platform should change: open a PR against the owning module, deploy through the pipeline. Never fix it in the portal, because the next deploy reverts it.
2. **Accept it with a reason** when the design already mitigates it (for example "Storage accounts should restrict network access" on the `stfl…` accounts, `ADR-023`): add an exemption in Bicep (§5.3) with category `Mitigated` and a description citing the ADR.
3. **Expected findings, no action:** the jump host's "Management ports should be closed" stays healthy because nothing allows 22/3389 at the NIC; "Management ports should be protected with just-in-time network access control" is healthy once §4 step 8 has run.

Defender's **Exempt** button writes an exemption on its own assignment of the benchmark, `SecurityCenterBuiltIn` (display name "ASC Default"), not on `defenstack-mcsb`. The benchmark is assigned twice on purpose (`ADR-027`): codify any lasting exemption in Bicep against `defenstack-mcsb` as well, or accept its audit row.

Security alerts of severity High email `SECURITY_CONTACT_EMAILS` and the subscription Owners. Investigate them in Microsoft Sentinel (the tenant-based Defender for Cloud connector, runbook 06 §5.1).

### 5.2 Audit week and the audit-to-deny switch

1. **Run under `DoNotEnforce` for about a week** after §4 step 7, including at least one workload deploy of each environment, so every resource has been evaluated.
2. **Review compliance.** Trigger a fresh evaluation, then summarise and list the non-compliant resources:

   ```powershell
   az policy state trigger-scan --no-wait
   az policy state summarize --query "policyAssignments[?contains(policyAssignmentId, 'defenstack-')].{assignment:policyAssignmentId, nonCompliant:results.nonCompliantResources}" -o table
   az policy state list --filter "complianceState eq 'NonCompliant'" --query "[?starts_with(policyAssignmentName, 'defenstack-deny') || starts_with(policyAssignmentName, 'defenstack-allowed')].{assignment:policyAssignmentName, resource:resourceId}" -o table
   ```

   The scan takes up to 30 minutes; `summarize` then reflects it. The first command lists the 11 `defenstack-` assignments with their non-compliant resource counts.
3. **Every row of the second list blocks the switch** until it is fixed in Bicep, deleted, or exempted (§5.3). Known rows that are **not** blockers:
   - `defenstack-audit-diagnostic-settings` on the `stfl…` accounts' blob services: Phase 6 gives the flow-log accounts no diagnostic setting, so they report non-compliant. Expected; that assignment never blocks.
   - `defenstack-mcsb`: benchmark findings are handled in §5.1, not here.
   - Anything in `defenStack`: it reports **Exempt** while the waiver lasts.
   - Azure-created groups such as `NetworkWatcherRG` or `DefaultResourceGroup-*` outside West US 3 / East US: they report non-compliant for the resource-group locations assignment, but the switch blocks nothing that already exists. Move nothing; accept them, or exempt them (§5.3).
4. **Switch.** Change `param denyEnforcement = 'Default'` in `params/governance.bicepparam` and update the Params test "starts audit-first for dev and prod" to expect `Default`, in one PR. Then repeat §4 steps 1, 5, 6 and 7. The what-if shows only `enforcementMode` changing to `Default` on the 9 deny assignments.
5. **Check:** `az policy assignment list --query "[?starts_with(name,'defenstack-')].{name:name, mode:enforcementMode}" -o table` shows `Default` on all 11.

A command-line override (`--parameters denyEnforcement=Default`) works for a one-off test, but commit the change: the next deploy from the file would quietly return to `DoNotEnforce`.

### 5.3 Exemption procedure and the ordering trap

**When to exempt:** only a resource whose design meets the policy's intent another way (`Mitigated`), or one that is being retired (`Waiver`, always with `expiresOn`). Every exemption needs a reviewer and an ADR or runbook reference in its description.

**How:**
1. Add the exemption in Bicep, following `modules/governance/flowLogStorageExemption.bicep`: an RG-scope module that declares the target `existing` and creates `Microsoft.Authorization/policyExemptions@2026-01-01-preview` scoped to it, with `policyAssignmentId`, `exemptionCategory`, `displayName`, `description` and (for a waiver) `expiresOn`. Call it from `governance.bicep` and add tests.
2. Deploy governance (§4 steps 1, 5–7).
3. **Emergency only** (a blocked production change): create it by hand, then codify it within a week:

   ```powershell
   az policy exemption create --name defenstack-temp-<reason> --policy-assignment /subscriptions/<sub>/providers/Microsoft.Authorization/policyAssignments/<assignment> --exemption-category Waiver --expires-on 2026-11-01T00:00:00Z --scope <resource or resource group ID> --description 'Temporary: <ticket>. Codify in governance.bicep (runbook 07 §5.3).'
   ```

4. Check: `az policy exemption list --query "[].{name:name, category:exemptionCategory, expires:expiresOn}" -o table` (add `--scope <resource group ID>` for resource-group and resource exemptions).

**The ordering trap.** An exemption, and the JIT Requester role assignment, needs its target to exist when governance deploys. Under `Default` enforcement, a new flow-log account (public network access `Enabled`) is denied before its exemption can exist. So **adding an environment or a region** always follows this sequence:

1. Set `denyEnforcement = 'DoNotEnforce'` and redeploy governance (§4 steps 5–7).
2. Deploy the workload for the new environment or region (runbook 01; runbook 06 for its flow logs).
3. Add the environment to `environments`, or the region to `environmentRegions`, in `params/governance.bicepparam` (and the admin group, for a new environment).
4. Redeploy governance: it creates the new flow-log exemption, allows the new public IP names and assigns the JIT role.
5. Set `denyEnforcement = 'Default'` and redeploy governance.

Turning on the prod warm standby's admin access during failover needs no step: its public IPs are already allowed.

**The legacy waiver.** It exempts `defenStack` from the 9 deny assignments until `legacyWaiverExpiresOn`. The committed date `2027-03-31` is a **placeholder to confirm** with the platform owner. When runbook 01a has deleted `defenStack`, set `legacyResourceGroupName = ''` and redeploy (the exemptions went with the group). If the teardown slips past the date, extend `legacyWaiverExpiresOn` with a dated reason in runbook 01a, and redeploy before the old date passes.

### 5.4 Requesting JIT access to the jump host

Every SSH or RDP session to the jump host now starts with a JIT request. The jump host runs in the primary region only.

1. **Activate the admin group membership** in PIM (runbook 03 §5.5). It carries both `Virtual Machine Administrator Login` and **DefenStack JIT Requester**.
2. **Request access.**
   - **Portal:** **Microsoft Defender for Cloud** → **Workload protections** → **Just-in-time VM access** → **Configured** → tick the jump host → **Request access**. For each port you need (22 Linux, 3389 Windows): **On**, **Allowed source IP**: **IP range** = the Bastion subnet (dev `10.21.0.64/26`, prod `10.1.0.64/26`) to connect through Bastion, or the VPN pool (dev `172.16.210.0/24`, prod `172.16.200.0/24`) to connect over the VPN; **Time range** at most 3 hours; a justification → **Open ports**. The VM's own **Connect** blade no longer offers the request in many regions; use Defender for Cloud, or the VM's **Configuration** → **Just-in-time VM access**.
   - **Azure CLI.** `az security jit-policy` lists and shows policies; request access through the REST API. The `initiate` body (API `2020-01-01`) takes one object per port, each with a single source and a required end time, so send **one request per access path**: the Bastion subnet (dev `10.21.0.64/26`, prod `10.1.0.64/26`) or the VPN pool (dev `172.16.210.0/24`, prod `172.16.200.0/24`). Use port `3389` for a Windows jump host:

     ```powershell
     az security jit-policy list --query "[].{name:name, rg:resourceGroup, location:location}" -o table
     $vmId = az vm list --resource-group rg-defenstack-dev-wus3 --query '[0].id' -o tsv
     $source = '10.21.0.64/26'   # the Bastion subnet; or '172.16.210.0/24', the VPN pool
     $endTimeUtc = (Get-Date).ToUniversalTime().AddHours(3).ToString('yyyy-MM-ddTHH:mm:ssZ')
     $body = @{
       virtualMachines = @(@{ id = $vmId; ports = @(@{ number = 22; allowedSourceAddressPrefix = $source; endTimeUtc = $endTimeUtc }) })
       justification   = 'Runbook 07 §5.4: <ticket>'
     } | ConvertTo-Json -Depth 6 -Compress
     Set-Content -Path jit-request.json -Value $body -Encoding ascii
     az rest --method post --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Security/locations/westus3/jitNetworkAccessPolicies/default/initiate?api-version=2020-01-01" --body '@jit-request.json'
     ```

   Expected: the response lists the port with `status: Initiated` and the `endTimeUtc` you sent. If the request is refused for its shape, use the portal path above (§9, live-only risks).
3. **Connect** through Bastion or the VPN (runbook 03 §5.2 and §5.3).
4. The grant ends on its own at `endTimeUtc`. **Any pipeline deploy of that environment also ends it**, because the deploy rewrites the NIC NSG (`ADR-028`). Request again after a deploy.

## 6. Validation

| Check | Command | Expected result |
|---|---|---|
| Defender plans | `az security pricing list --query "value[].{plan:name, tier:pricingTier, subPlan:subPlan}" -o table` | `Standard` for `VirtualMachines` (`P2`), `AppServices`, `StorageAccounts` (`DefenderForStorageV2`), `KeyVaults`, `Arm`, `CloudPosture` |
| Servers extensions | `az security pricing show -n VirtualMachines --query "extensions[].{name:name, on:isEnabled}" -o table` | `AgentlessVmScanning` `True` |
| Storage malware cap | `az security pricing show -n StorageAccounts --query "extensions[?name=='OnUploadMalwareScanning'].additionalExtensionProperties" -o json` | `CapGBPerMonthPerStorageAccount` = `5000` |
| Security contact | `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Security/securityContacts/default?api-version=2023-12-01-preview" --query "properties.{emails:emails, roles:notificationsByRole.roles, sources:notificationsSources}" -o json` | The `SECURITY_CONTACT_EMAILS` addresses, `Owner`, `Alert` at `High` |
| Assignments | `az policy assignment list --query "[?starts_with(name,'defenstack-')].{name:name, mode:enforcementMode}" -o table` | 11 rows; `DoNotEnforce` on the 9 deny assignments during the audit week, `Default` after §5.2; `defenstack-mcsb` and `defenstack-audit-diagnostic-settings` always `Default` |
| Public IP allowlist | `az policy assignment show -n defenstack-deny-public-ip --query "parameters.allowedNames.value" -o tsv` | The 12 names (`pip-afw-`, `pip-bas-`, `pip-vpng-…-1`, `-2` for dev-wus3, prod-wus3, prod-eus) |
| Flow-log exemption | `az policy exemption list --scope <stfl… account ID> --query "[].{name:name, category:exemptionCategory}" -o table` | `defenstack-flow-log-storage-public-network`, `Mitigated` |
| Flow-log Defender for Storage override | `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-defenstack-<env>-<region>/providers/Microsoft.Storage/storageAccounts/<stfl… account>/providers/Microsoft.Security/defenderForStorageSettings/current?api-version=2025-01-01" --query "properties.{on:isEnabled, override:overrideSubscriptionLevelSettings, malware:malwareScanning.onUpload.isEnabled, sdd:sensitiveDataDiscovery.isEnabled}" -o json` | `on` `true`, `override` `true`, `malware` `false`, `sdd` `false` |
| Legacy waiver | `az policy exemption list --resource-group defenStack --query "[].{name:name, expires:expiresOn}" -o table` | 9 rows, expiry `2027-03-31T23:59:59Z` |
| Deny works (after §5.2 only) | `az network public-ip create -g rg-defenstack-dev-wus3 -n pip-test-deny --sku Standard` | `RequestDisallowedByPolicy` naming `defenstack-deny-public-ip`, with "Exemptions: runbook 07." If the IP is created instead, delete it (`az network public-ip delete -g rg-defenstack-dev-wus3 -n pip-test-deny`) and check that `denyEnforcement` is `Default` |
| JIT role | `az role definition list --name "DefenStack JIT Requester" --custom-role-only true --query "[0].permissions[0].actions" -o tsv` | The 7 actions of `modules/governance/jitRequesterRole.bicep` |
| JIT role assignment | `az role assignment list --scope /subscriptions/<sub>/resourceGroups/rg-defenstack-<env>-wus3 --role "DefenStack JIT Requester" --query "[].principalId" -o tsv` | The environment's admin group |
| JIT policy | `az security jit-policy show -l westus3 -g rg-defenstack-<env>-wus3 -n default --query "virtualMachines[0].ports[].{port:number, sources:allowedSourceAddressPrefixes, max:maxRequestAccessDuration}" -o json` | `22` and `3389`, the Bastion subnet and VPN pool, `PT3H` |
| Closed without a grant | `az network nsg rule list -g rg-defenstack-<env>-wus3 --nsg-name <vm>-nsg --query "[?direction=='Inbound'].{name:name, priority:priority, access:access}" -o table`; then over the VPN `Test-NetConnection <vm private IP> -Port 22` | `deny-ssh-rdp-inbound` 4000 `Deny`, `deny-unsolicited-inbound` 4096 (plus any JIT-created `SecurityCenter-JITRule…` deny rules); `TcpTestSucceeded : False` |
| Reachable with a grant | §5.4, then the same two commands | A `SecurityCenter-JITRule…` `Allow` rule above priority 4000 on `<vm>-nsg`; `TcpTestSucceeded : True`; `az ssh vm --ip <vm private IP>` gives a prompt |
| Defender for Endpoint (when `enableVirtualMachine = true`) | `az vm extension list -g rg-defenstack-<env>-wus3 --vm-name <vm> --query "[?starts_with(name,'MDE.')].{name:name, state:provisioningState}" -o table` | `MDE.Linux` or `MDE.Windows`, `Succeeded` (Defender deploys it within a few hours of §4 step 7). If it is missing or failed, see §9, live-only risks |
| Subnet NSG unchanged | `az network nsg rule show -g rg-defenstack-<env>-wus3 --nsg-name vnet-defenstack-<env>-wus3-spoke-management-nsg -n allow-management-ssh-rdp --query "{priority:priority, sources:sourceAddressPrefixes}" -o json` | `100`, the Bastion subnet and VPN pool. Also note whether JIT added rules here (§9, live-only risks) |

Paste every output into the Phase 7 PR (spec §6 definition of done).

## 7. Rollback

- **Stop blocking at once:** set `denyEnforcement = 'DoNotEnforce'` and redeploy governance (§4 steps 5–7). This is the first move for any deny that blocks a legitimate change; it keeps compliance reporting.
- **Remove one assignment:** `az policy assignment delete --name <defenstack-…>`, then remove it from `modules/governance/policies.bicep` so the next deploy does not bring it back. Delete its exemptions first (`az policy exemption delete --name <name> --scope <scope>`).
- **Defender plans:** `az security pricing create -n <plan> --tier Free`. Turning `VirtualMachines` to Free ends JIT: Defender removes the JIT policy's effect, and the jump host is then unreachable (the NIC deny stays). Revert the NIC change first (next bullet) if admins still need access.
- **JIT on the jump host:** revert the Phase 7 change to `modules/virtualMachine.bicep` and deploy through the pipeline. The static NIC allow returns, and incremental mode leaves the JIT policy resource behind: `az security jit-policy delete -l westus3 -g rg-defenstack-<env>-wus3 -n default`.
- **JIT role:** delete its assignments (`az role assignment delete --role "DefenStack JIT Requester" --scope <rg ID>`), then the definition (`az role definition delete --name "DefenStack JIT Requester"`).
- **Security contact:** `az rest --method delete --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Security/securityContacts/default?api-version=2023-12-01-preview"`.
- Deployments are incremental: removing a resource from the template never deletes it in Azure. Every removal above is a manual command.

## 8. Operations

- **Weekly:** §5.1 recommendations and alerts; `az policy state summarize` for new non-compliance; exemptions close to expiry (`az policy exemption list --query "[?expiresOn!=null].{name:name, expires:expiresOn}"`).
- **New public IP:** a module that creates a public IP fails the test suite until its name is added to the `publicIpNames` function in `governance.bicep`; deploy governance before the workload that creates it.
- **New environment or region:** §5.3, the ordering trap.
- **Admin changes:** PIM eligibility only (runbook 03 §8). The JIT Requester role follows the group.
- **Malware scanning cap:** raise `malwareScanCapGbPerMonth` only after Defender reports an account hitting the cap; each GB scanned is billed.
- **Contact changes:** set `SECURITY_CONTACT_EMAILS` and redeploy governance.
- **JIT grants and deploys:** schedule workload deploys outside admin sessions; a deploy ends every active grant (§5.4 step 4).
- **The JIT `default` policy belongs to Bicep:** each pipeline deploy replaces the resource group's whole `default` JIT policy, including its `virtualMachines` list, so a VM added to JIT in the portal is dropped at the next deploy (`ADR-028`). JIT for any other VM belongs in Bicep, next to the jump host's in `modules/virtualMachine.bicep`.
- **Changing an `adminGroupObjectIds` value:** deploys are incremental, so the old group keeps its JIT Requester assignment. Delete it by hand after the redeploy: `az role assignment delete --assignee <old group object ID> --role "DefenStack JIT Requester" --scope /subscriptions/<sub>/resourceGroups/rg-defenstack-<env>-wus3`.
- **Cost drivers** (`docs/cost.md` "Phase 7 delta"): Defender for Servers P2 per server, Defender for Storage per account plus malware scanning per GB, App Service, Key Vault, Resource Manager and CSPM per billable resource. Azure Policy and JIT add no charge.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| `securityContactEmails` "minimum length" / array length error at validate | `SECURITY_CONTACT_EMAILS` is not set in this session | §4 step 5 |
| `AuthorizationFailed` on `Microsoft.Security/pricings/write` or `policyAssignments/write` | Security Admin is not active | Activate it in PIM (§2) and retry after a few minutes |
| `AuthorizationFailed` on `roleDefinitions/write` or `roleAssignments/write` | User Access Administrator is not active | Activate it in PIM, or use Owner |
| `Another update operation is in progress` on a pricing | A concurrent change to the plans (portal or another deploy) | Wait 5 minutes and re-run; the template already updates one plan at a time |
| `ResourceGroupNotFound` or `ParentResourceNotFound` on `governance-flow-log-exemption-…`, `governance-jit-requester-…` or `governance-legacy-waiver` | A listed stamp or its flow-log account, or the legacy group, does not exist | §5.3 ordering; narrow `environments` / `environmentRegions`, or set `legacyResourceGroupName = ''` |
| `RoleDefinitionWithSameNameExists` | Another subscription in the tenant already has a custom role named `DefenStack JIT Requester` (role names are tenant-wide) | See "Live-only risks" |
| `RequestDisallowedByPolicy` in a workload deploy | `denyEnforcement` is `Default` and the resource breaks a deny assignment | Fix the resource; or, if it is legitimate, §5.3. To unblock a release now: §7 first bullet |
| Workload deploy fails on `jitNetworkAccessPolicies` | Defender for Servers is not on, or the plan change has not propagated | Deploy governance first (§4 order); re-run the workload deploy after 15 minutes |
| SSH/RDP to the jump host times out | No active JIT grant, the grant expired, or a deploy ended it | §5.4 |
| JIT request fails with `AuthorizationFailed` on `initiate/action` | The PIM membership is not active, or the role assignment is missing in that resource group | Activate PIM, sign in again; check the §6 "JIT role assignment" row |
| JIT request succeeds but the port stays closed | JIT programmed only the subnet NSG, or the request's source is outside the VPN pool / Bastion subnet | §6 "Reachable with a grant"; see "Live-only risks" |

### Live-only risks

These cannot be proved offline. Each is first exercised by the first deployment that uses it; record the outcome in the Phase 7 PR.

| Risk | How it shows | Fallback |
|---|---|---|
| **Preview APIs: policy exemptions and the security contact.** `policyExemptions@2026-01-01-preview` and `securityContacts@2023-12-01-preview` have no GA version (`ADR-029`); the contact's `isEnabled` / `notificationsSources` shape comes from the Bicep types, not a live call | Deploy fails on an exemption or `governance-security-contacts` with an API version or schema error, or §6 "Security contact" shows no `notificationsSources` | **Fallback:** for exemptions, move to the newest preview the template reference lists (`2024-12-01-preview`, then `2022-07-01-preview`) and update the pinned-version tests; or create them by hand (§5.3 step 3) and remove the module. For the contact: set it in the portal (**Defender for Cloud** → **Environment settings** → the subscription → **Email notifications**: the addresses, role **Owner**, severity **High**), and remove the module until the API settles |
| **Whether "Allowed locations" skips `global`.** The built-in is believed to exempt `global` itself; `global` is listed anyway (harmless) | Front Door, DNS zones or the action group show non-compliant in `defenstack-allowed-locations` during the audit week | **Fallback:** none needed if they do not; if they do, the list already contains `global`, so check the resource's `location` value and add exactly that value |
| **Effect of the resource-group locations policy.** No `effect` is passed, on the understanding that its default is `Deny` | The audit week shows the assignment with `effect` `Audit`, or a non-West US 3 / East US group is created after §5.2 without a deny | **Fallback:** read `az policy definition show -n e765b5de-1225-4ba3-bd56-1ac6695af988 --query parameters`; if it has an `effect` parameter, pass `effect: 'Deny'` in `modules/governance/policies.bicep` with a test |
| **JIT rule behaviour after an NSG redeploy, and which NSG JIT edits.** The NIC NSG's rule list is rewritten by every pipeline deploy, which removes JIT's rules; whether Defender also programs the subnet NSG is not documented for a VM with both | §5.4 grant lost after a deploy (expected, `ADR-028`); a grant that never opens the port; `SecurityCenter-JITRule…` rules on `<spoke VNet>-management-nsg` | Re-request after each deploy. If a grant never opens the port: check both NSGs' effective rules (`az network nic list-effective-nsg -g <rg> -n <vm>-nic`). If JIT writes only to the subnet NSG, move `deny-ssh-rdp-inbound` from the NIC NSG to the subnet NSG (priority 4000) and keep the NIC allow-free, then record it in `ADR-028` |
| **The JIT requester role's action list.** The 7 actions follow Microsoft's least-privilege guidance as researched, not a live test | A requester with an active PIM membership gets `AuthorizationFailed` naming another action, or the portal shows no **Request access** button | **Fallback:** add exactly the action the error names to `roleActions` in `modules/governance/jitRequesterRole.bicep` (and its test), redeploy governance. As a stopgap, assign the built-in **Security Admin** at the jump host's resource group through PIM |
| **The malware scanning cap property.** `CapGBPerMonthPerStorageAccount` is passed as a string under `additionalExtensionProperties` | §6 "Storage malware cap" shows `10000` or nothing | **Fallback:** set the cap in the portal (Defender for Cloud → Environment settings → Storage → Settings) and open an issue to correct the property name in `modules/governance/defenderPlans.bicep` |
| **Default sub-plans and extensions.** `KeyVaults`, `Arm` and `CloudPosture` send no sub-plan or extensions, so Azure picks its current default; a subscription already on a legacy sub-plan may keep it | §6 "Defender plans" shows a legacy sub-plan (`PerTransaction`, `PerSubscription`) | **Fallback:** set the current sub-plan explicitly in `defenderPlans.bicep` (`PerKeyVault`, `PerApiCall`) with a test, after confirming the names with `az security pricing show` |
| **JIT policy creation by the pipeline identity.** RG `Contributor` includes the JIT write, but Defender may also read the subscription's pricing on that call | Workload deploy fails on `jitNetworkAccessPolicies` with `LinkedAuthorizationFailed` or `AuthorizationFailed` naming `Microsoft.Security/pricings/read` | **Fallback:** add only that read action to the subscription custom role in `scripts/New-GitHubDeploymentIdentity.ps1` (and its tests), re-run the identity script (runbook 00b), and record the change in `ADR-028` |
| **Tenant-wide role name.** `DefenStack JIT Requester` must be unique in the tenant | `RoleDefinitionWithSameNameExists` on a second subscription's governance deploy | **Fallback:** add the subscription's display name to `roleName` in `jitRequesterRole.bicep` for that subscription's copy, and update the test |
| **Exemption expiry in the past.** ARM may refuse to create or update an exemption whose `expiresOn` has passed | Governance redeploy fails on `governance-legacy-waiver` after `legacyWaiverExpiresOn` | **Fallback:** extend the date (§5.3) or set `legacyResourceGroupName = ''` |
| **Benchmark members that need an identity.** `defenstack-mcsb` has no managed identity; no member is expected to need one | Assignment creation fails with a message about a missing identity for `DeployIfNotExists`/`Modify` | **Fallback:** add a system-assigned identity and a location to that one assignment in `policies.bicep`, with no remediation tasks, and record it in `ADR-027` |
| **The JIT request body.** §5.4 sends the `initiate` shape of API `2020-01-01` (per port: `number`, one `allowedSourceAddressPrefix`, `endTimeUtc`) from the REST reference, not a live call; check it on the first request | `az rest` returns `BadRequest` or a schema error naming a port property | **Fallback:** request through the portal (§5.4), then correct the example from the error and its Docs test |
| **Defender for Endpoint egress.** The firewall allows only MDE's streamlined endpoint, `*.endpoint.security.microsoft.com` on 443, from the management subnet (rule `defender-for-endpoint` in `platform-egress`); that the sensor needs nothing more is assumed | §6 "Defender for Endpoint" shows no `MDE.*` extension or a failed one, the device does not report in the Defender portal, or `AZFWApplicationRule` shows denies from the jump host | **Fallback:** run the MDE client analyser's connectivity check on the jump host, and add the region-specific URLs Microsoft lists for the tenant's data location to that rule in `modules/firewallPolicyRules.bicep`, with a test |
| **The flow-log Defender for Storage override needs its account.** `defenderForStorageSettings/current` is written on each `stfl…` account | `ResourceNotFound` or `ParentResourceNotFound` on `governance-flow-log-exemption-…` | **Fallback:** the same as the exemption beside it: §5.3, "The ordering trap" |
| **The JIT `default` policy is replaced on every deploy.** The pipeline PUTs the whole policy, so its `virtualMachines` list is exactly the jump host | A VM added to JIT in the portal is gone after a workload deploy | **Fallback:** add that VM's JIT entry in Bicep (§8) |
| **Role replication on the first governance deploy.** The JIT Requester role is created and assigned in the same deploy | `RoleDefinitionDoesNotExist` on `governance-jit-requester-…` | **Fallback:** re-run §4 step 7 after about 2 minutes |
| **Diagnostic audit of child types.** If `7f89b1eb-583c-429a-8828-af049802c1d9` has mode `Indexed`, child types such as `Microsoft.Storage/storageAccounts/blobServices` may not be evaluated | During the audit week, no blob service appears in `defenstack-audit-diagnostic-settings` compliance, not even the `stfl…` ones that have no setting | **Fallback:** check `az policy definition show -n 7f89b1eb-583c-429a-8828-af049802c1d9 --query mode`; if it is `Indexed`, drop `blobServices` from `diagnosticResourceTypes` in `governance.bicep` (and its test) and audit blob diagnostic settings with a Resource Graph query instead |
