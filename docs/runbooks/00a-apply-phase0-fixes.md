# 00a - Apply Phase 0 foundation fixes

> Owning modules: all files under `modules/` and `main.bicep`. Spec: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §2 (F1–F13).

## 1. Purpose and scope
Applies the Phase 0 defect fixes to the existing `defenStack` resource group (dev) **in place**. No resource is replaced. The fixes are listed per finding in §5–§7. Greenfield-only changes (zones, plan rename, subnet rename, subscription scope) are **not** part of this runbook; they arrive with Phase 1.

## 2. Prerequisites
- Azure CLI 2.90 or later: `az version`.
- Bicep CLI 0.47.16 or later: `bicep --version`.
- PowerShell 5.1 or 7.
- Operator role on `defenStack`: `Owner`, or `Contributor` plus `Role Based Access Control Administrator`. Role assignments are created and one is deleted in §5.
- Signed in to the correct subscription:

  ```powershell
  az login
  az account set --subscription <subscription-id>
  az account show --query "{subscription:id,tenant:tenantId}" -o table
  ```

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `managementSourceCidrs` | `[]` | `[]` until Phase 3 (then AzureBastionSubnet + P2S pool) | Only named admin sources may reach SSH/RDP; empty = deny all |

## 4. Step-by-step deployment
1. Run the local test suite and confirm every test passes:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
   ```

2. Validate the template against Azure:

   ```powershell
   $resourceGroup = 'defenStack'
   az deployment group validate `
     --resource-group $resourceGroup `
     --parameters params/dev.bicepparam `
     --output table
   ```

   Expected: `provisioningState` `Succeeded`.

3. Preview the changes:

   ```powershell
   az deployment group what-if `
     --resource-group $resourceGroup `
     --parameters params/dev.bicepparam `
     --exclude-change-types Ignore NoChange
   ```

   Compare every `~ Modify`, `+ Create` and `- Delete` line against the "Expected what-if" list in each §5 subsection. **Stop if the what-if shows a `Delete` or `Create` that is not listed, or any change to a VNet address space, a subnet prefix, or the firewall public IP.**

4. Deploy:

   ```powershell
   az deployment group create `
     --resource-group $resourceGroup `
     --name "phase0-$(Get-Date -Format yyyyMMddHHmm)" `
     --parameters params/dev.bicepparam `
     --output table
   ```

5. Run every manual step in §5, in order.
6. Run every validation in §6 and paste the outputs into the Phase 0 PR.

Until Task 11 creates `params/dev.bicepparam`, use `--template-file main.bicep --parameters environmentType=dev` instead.

## 5. Manual and post-deployment steps

### F1/F2 - Management subnet isolation and forced tunnelling
**Change:** the `virtual-machines` subnet gets its own NSG (`<spoke>-virtual-machines-nsg`) and its own route table (`<spoke>-virtual-machines-egress-rt`). BGP route propagation is disabled on both spoke route tables so that future VPN gateway routes cannot bypass the firewall.

**Expected what-if:**
- `+ Create` for the new NSG and the new route table.
- `~ Modify` on the spoke VNet: the `virtual-machines` subnet's `networkSecurityGroup.id` and `routeTable.id` change.
- `~ Modify` on `<spoke>-appservice-egress-rt`: `disableBgpRoutePropagation` goes false → true.

**Manual steps:** none.

## 6. Validation
| Check | Command | Expected result |
|---|---|---|
| Management subnet has its own NSG | `az network vnet subnet show -g defenStack --vnet-name <spoke-vnet> -n virtual-machines --query "{nsg:networkSecurityGroup.id,rt:routeTable.id}" -o json` | `nsg` ends `-virtual-machines-nsg`; `rt` ends `-virtual-machines-egress-rt` |
| BGP propagation disabled | `az network route-table list -g defenStack --query "[].{name:name,bgpOff:disableBgpRoutePropagation}" -o table` | `bgpOff` = `True` for both spoke route tables |
| No admin inbound yet | `az network nsg rule list -g defenStack --nsg-name <spoke-vnet>-virtual-machines-nsg -o table` | Only `deny-unsolicited-inbound` (4096) |

## 7. Rollback
General rollback: redeploy the last good commit from `main` with the same commands in §4. Per-fix exceptions are listed below.

- **F1/F2:** redeploy the previous commit. ARM re-points the subnet to the App Service NSG and route table; the new NSG and route table remain and can be deleted afterwards with `az network nsg delete` / `az network route-table delete`.

## 8. Operations
See the per-fix notes in §5.

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
