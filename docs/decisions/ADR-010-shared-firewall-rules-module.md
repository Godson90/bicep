# ADR-010: Shared firewall rules module instead of one parent policy per region

## Context
`docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 asked for a
parent Firewall Policy in `rg-defenstack-<env>-global`, with a child policy per
region inheriting from it, so that baseline rules could be defined once and
consumed by both the West US 3 and East US stamps.

Azure requires a parent firewall policy and its child policies to live in the
**same region** as each other. `rg-defenstack-<env>-global` is not itself a
region, and a policy created there would have to pick one region regardless;
whichever region it picked, it could not parent a child policy in the other
region (West US 3 cannot parent an East US child, and vice versa). One parent
policy therefore cannot serve both the West US 3 primary and the East US
warm-standby stamp in the same environment.

Given that constraint, the user chose a shared **rules module** (regional
policies stay independent, but their rule content is defined once) over a
one-parent-per-region compromise that would still need two independently
maintained rule sets.

## Decision
- Each stamp's firewall policy (`modules/azureFirewall.bicep`) includes
  `modules/firewallPolicyRules.bicep` as a child module, deploying three rule
  collection groups: `dns-egress` (priority 100), `platform-egress` (priority
  150), and the optional `approved-https-egress` (priority 200, only when
  `allowedOutboundFqdns` is non-empty).
- Regional differences are expressed entirely through parameters passed into
  the shared module: `spokeAddressPrefixes`, `managementAddressPrefixes`, and
  `allowedOutboundFqdns`. The rule *logic* is identical for every stamp; only
  the data differs.
- The rule collection groups are dependency-chained (`platform-egress` depends
  on `dns-egress`, `approved-https-egress` depends on `platform-egress`)
  because Azure Firewall Policy does not allow concurrent updates to rule
  collection groups on the same policy. The firewall resource itself is
  applied last, after every rule collection group exists.

## Consequences
- One source of truth for baseline rule logic (`modules/firewallPolicyRules.bicep`),
  with no cross-region parent/child constraint to work around.
- There is no Firewall Manager "base policy" view: an operator cannot see one
  policy that visibly governs every region from the portal's Firewall Manager
  blade. Rules also cannot be delegated to a separate team through policy-level
  RBAC, since there is no shared policy resource to scope that RBAC to.
- A baseline rule change (for example, adding an FQDN tag) redeploys every
  stamp's policy, one rule collection group deployment per stamp, rather than
  one parent policy deployment that every child inherits from automatically.

## Revisit when
A separate team must own baseline rules independently of the stamps that
consume them, or the design moves to Virtual WAN / Firewall Manager secured
hubs, which support a genuinely shared base policy across regions through a
different resource model.

Link: https://learn.microsoft.com/en-us/azure/firewall-manager/policy-overview
