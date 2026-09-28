# ADR-008: Warm standby in East US, dev stays single-region

## Context
`docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §1 calls for an
active/passive disaster-recovery design: West US 3 as the active (primary) region,
East US as a warm standby that can be scaled out during a failover. That design does
not by itself say whether every environment needs a secondary region.

The user chose to run the dev workspace in the primary region (West US 3) only. Dev
exists to validate changes before they reach prod; it does not need to rehearse
failover, and paying for a second dev firewall, plan and workspace replication target
does not buy anything dev-specific.

## Decision
- **Prod West US 3 (primary):** zone-redundant, 3-instance P-v3 App Service plan.
  Everything else (firewall, Key Vault, storage, private endpoints, Log Analytics
  workspace) is deployed at full production strength.
- **Prod East US (warm standby):** always deployed in prod, not conditional. Firewall,
  a 1-instance P-v3 App Service plan (non-zonal), Key Vault, storage and private
  endpoints are stood up so that only a scale-out is needed during a real failover,
  not a from-scratch deployment. Azure Bastion and the VPN gateway are deferred:
  they land later, behind a flag, in Phase 3, alongside the rest of the admin-access
  redesign.
- **Dev (West US 3 only):** a single, non-zonal S1, 1-instance App Service plan. No
  East US resources are deployed for dev.
- **Log Analytics workspace replication:** the prod workspace replicates to East US;
  the dev workspace does not replicate anywhere.
- PSRule failures that follow directly from these choices — non-zonal, single-instance
  App Service plans in dev and in the East US standby, and no workspace replication in
  dev — are suppressed **only for the specific named targets** that this decision
  applies to (`asp-defenstack-dev-wus3`, `asp-defenstack-prod-eus`,
  `log-defenstack-dev`) via `.ps-rule/Suppression.Rule.yaml`. Prod's West US 3
  (primary) resources are not named in any suppression group and PSRule continues to
  enforce zone redundancy and replication against them.

## Consequences
- Failing over to East US requires a scale-out of the standby App Service plan
  from 1 instance to 3 instances (`runbook 01` §8: `az appservice plan update
  --number-of-workers 3`); the East US plan stays non-zonal — zone redundancy is
  fixed at plan creation and is not part of the failover scale-out — so this is
  not the same as the prod primary's zone-redundant configuration, and the
  scale-out itself is not instantaneous.
- Dev cannot rehearse a regional failover, since it has no secondary region at all.
- Cost is lower for dev by roughly one Azure Firewall (and the other East US
  resources it would otherwise need) compared with running two regions everywhere.

## Revisit when
The recovery time objective (RTO) requires a hot standby (East US already at full
zone-redundant, multi-instance capacity with no scale-out step), or the DR drill in
Phase 8 shows that the East US scale-out time itself breaks the agreed RTO.
