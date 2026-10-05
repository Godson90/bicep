# ADR-028: Just-in-time access to the jump host: the NIC NSG denies, JIT opens, the subnet NSG bounds

## Context
`ADR-014` deferred Defender just-in-time (JIT) VM access to Phase 7, which turns on Defender for Servers Plan 2. JIT works by adding time-bound allow rules to the NSGs in front of a VM. The jump host has two NSGs: the `management` subnet NSG and its own NIC NSG. Until Phase 7, both allowed SSH (22) and RDP (3389) at priority 100 from the Bastion subnet and the VPN client pool, so the ports were open to those sources all the time. Bicep owns every NSG rule list: each pipeline deploy rewrites it, which removes any rule JIT added. Microsoft does not document which NSG JIT edits when a VM has both.

## Decision
- **NIC NSG (`<vm>-nsg`, closest to the VM): no allow for 22/3389.** An explicit `deny-ssh-rdp-inbound` (priority 4000, any source, ports 22 and 3389) replaces the static allow. Priorities 100–3999 stay free, so JIT's allow rules land above the deny. `deny-unsolicited-inbound` (4096) is unchanged.
- **Subnet NSG (`<spoke>-management-nsg`): unchanged.** `allow-management-ssh-rdp` (priority 100) still admits only the Bastion subnet and the VPN pool, plus any ADR-approved extra. It is the outer bound on who can ever connect, and it lets a JIT grant on the NIC through.
- Result: **closed unless JIT-granted, and reachable when granted.** Without a grant, the NIC deny drops the session. With one, the session passes the subnet allow and JIT's NIC allow. If Defender also programs the subnet NSG, its own deny sits below the existing allow, so nothing changes. The explicit deny keeps the ports closed even after a deploy has removed JIT's own deny rules.
- **The JIT policy** (`Microsoft.Security/locations/jitNetworkAccessPolicies@2020-01-01`, name `default`, kind Basic) is deployed by the pipeline with the jump host (`modules/virtualMachine.bicep`, primary region only): TCP 22 and 3389, allowed sources the same list as the subnet NSG, namely the Bastion subnet, the VPN pool and any ADR-approved management sources (`managementSourceCidrs`), at most 3 hours. The pipeline identity's resource-group `Contributor` covers it, and the identity script is unchanged.
- **Who may request:** a custom role, **DefenStack JIT Requester** (read and initiate JIT policies, read the VM and its NIC). `governance.bicep` defines it at subscription scope and assigns it to each environment's admin group at that environment's primary resource group, where the jump host runs. Assignment names are deterministic GUIDs. The group's membership is PIM-eligible, so one activation gives both the request right and `Virtual Machine Administrator Login` (runbook 03 §5.5).
- Rejected: leaving the NIC NSG without inline rules for JIT to own, as `ADR-014` suggested. Whether a PUT that omits `securityRules` keeps the existing rules is not documented, and the closed state would then depend on JIT's own deny rules surviving.

## Consequences
- **Every pipeline deploy of an environment rewrites the NIC NSG and ends any active JIT grant in it.** Admins request again after a deploy, and deploys are scheduled outside admin sessions. `deploy.yml` ignores governance-only commits, so those never cause it (`ADR-026`).
- **Each pipeline deploy replaces the resource group's whole `default` JIT policy,** including its `virtualMachines` list. A VM added to JIT in the portal is dropped at the next deploy, so JIT for any other VM belongs in Bicep (runbook 07 §8).
- Order matters: governance (Defender for Servers) deploys before the workload that creates the JIT policy (runbook 07 §4).
- Every admin session needs a JIT request first (runbook 03; runbook 07 §5.4). The VM **Connect** blade no longer offers the request in many regions, so requests go through Defender for Cloud or the REST API.
- Live-only (runbook 07 §9): which NSG JIT programs, the role's exact action list, whether the pipeline's JIT write also needs a subscription-level read, and the tenant-wide uniqueness of the role name. If JIT programs only the subnet NSG, the fallback is to move the deny there.

## Revisit when
Microsoft documents JIT behaviour with both NIC and subnet NSGs, or the jump host is deployed in a secondary region too (assign the role there as well).
