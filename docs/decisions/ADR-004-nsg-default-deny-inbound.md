# ADR-004: NSGs keep an explicit deny-all inbound rule (PSRule Azure.NSG.DenyAllInbound accepted)

## Context
PSRule for Azure's `Azure.NSG.DenyAllInbound` rule (AZR-000138) warns that when the
first inbound rule on an NSG denies all traffic, "some functions that affect the
reliability of your service may not work as expected," and recommends adding
permitted-traffic rules ahead of the deny.

This fires on two NSGs:
- `<spoke>-appservice-integration-nsg`: the delegated App Service regional VNet
  integration subnet. App Service VNet integration is outbound-only; the subnet never
  needs to accept inbound connections, so a permanent deny-all is correct, not a gap.
- `<spoke>-virtual-machines-nsg`: the management subnet. Its only inbound rule today is
  `deny-unsolicited-inbound` at priority 4096, by design (`docs/runbooks/00a-apply-
  phase0-fixes.md` §6, "No admin inbound yet" — expected: only `deny-unsolicited-
  inbound`). Phase 3 (Bastion, P2S VPN, jump host) adds a narrow `allow-management-ssh-
  rdp` rule ahead of the deny once `managementSourceCidrs` is populated
  (`modules/spokeNetwork.bicep`'s `managementInboundRules`), which will make this NSG
  pass the rule. The App Service integration subnet's NSG will not change and will keep
  failing this rule indefinitely.

Because `rule.exclude` in `ps-rule.yaml` operates per rule ID rather than per resource,
and one of the two affected NSGs is permanently and intentionally deny-all, this
finding cannot be resolved to zero by any phase.

## Decision
Accept the risk: default-deny-all-inbound is the intended zero-trust posture for both
NSGs until an explicit narrow allow rule is required. Exclude
`Azure.NSG.DenyAllInbound` in `ps-rule.yaml` with a reference to this ADR.

## Consequences
- No inbound connections reach the App Service integration or management subnets
  except through rules explicitly added later (Phase 3's admin-access allow rule for
  the management subnet).
- Re-evaluate this exclusion after Phase 3 lands: if the App Service integration NSG is
  still the only resource tripping this rule, consider whether PSRule supports a
  per-resource waiver at that point instead of a blanket rule exclusion.
