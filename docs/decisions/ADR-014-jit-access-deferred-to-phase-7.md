# ADR-014: Defender just-in-time VM access deferred to Phase 7

## Context
The spec (§3, "Management jump host") lists Defender for Cloud just-in-time (JIT) VM access for the jump host, in Phase 3. JIT needs **Microsoft Defender for Servers Plan 2** enabled on the subscription. The spec schedules the Defender plans for Phase 7. JIT also works by adding and removing rules on the VM's NSGs at request time, while this project manages every NSG rule in Bicep. Every redeploy replaces the rule list, so it would remove any active JIT allow rules and could fight JIT's own deny rules.

Phase 3 already gives the jump host a least-privilege, time-bound access model without JIT:
- Only Bastion and the VPN client pool can reach 22/3389.
- Both paths authenticate with Microsoft Entra ID.
- The `Virtual Machine Administrator Login` role is held by a group whose membership is PIM-eligible, activated for at most 4 hours with MFA and a justification (runbook 03 §5.5).

## Decision
Do not deploy a JIT policy in Phase 3. Phase 7, which enables Defender for Servers Plan 2, adds the `Microsoft.Security/locations/jitNetworkAccessPolicies` resource for the jump host. It also decides how JIT coexists with Bicep-managed NSGs, for example by keeping the JIT-managed rules on a NIC NSG that Bicep creates without inline rules.

## Consequences
- Until Phase 7, network reachability to the jump host is standing (from Bastion and VPN clients only). The time-bound control is PIM on the admin group, not JIT on the port.
- There is no Defender for Servers cost in Phase 3.
- Phase 7's plan must add JIT and resolve the NSG ownership question above. It is recorded in the "Revisit when" below.

## Revisit when
Phase 7 enables Defender for Servers Plan 2.
