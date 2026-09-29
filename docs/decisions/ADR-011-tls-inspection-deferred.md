# ADR-011: TLS inspection deferred on Premium firewalls

## Context
Azure Firewall Premium's TLS inspection (`transportSecurity` on the firewall
policy) decrypts, inspects, and re-encrypts outbound HTTPS traffic so IDPS and
URL filtering can see payloads instead of only TLS metadata. Enabling it
requires:

- An intermediate CA certificate held in Key Vault, which the firewall uses to
  generate per-session leaf certificates.
- A user-assigned managed identity on the firewall with a role granting it
  access to that certificate in Key Vault.
- Every client that traverses the firewall trusting the intermediate CA (or
  the chain up to it), otherwise TLS validation fails on every intercepted
  connection.

No enterprise CA is available to this project today, so there is no
certificate to import and no trust distribution mechanism to clients.

## Decision
Ship Azure Firewall Premium with IDPS and SNI-based FQDN filtering, but
**without** TLS inspection:

- No `transportSecurity` block on the firewall policy.
- No user-assigned managed identity on the firewall.
- No certificate in Key Vault for this purpose.

`modules/azureFirewall.bicep` and `modules/firewallPolicyRules.bicep` reflect
this: `intrusionDetection.mode` is set per `idpsMode`, but there is no
`transportSecurity` property and no identity block anywhere in the module.

## Consequences
- IDPS inspects unencrypted traffic in full, and for TLS traffic sees only
  metadata (SNI, certificate details) rather than the decrypted payload.
  HTTPS payload signatures are not inspected, and URL (path-level) filtering,
  which needs the decrypted request, is unavailable — filtering stays
  FQDN/SNI-based, as it already was on Standard.
- Threat intelligence and the FQDN allowlist (`approved-https-egress`,
  `dns-egress`, `platform-egress`) still apply in full; none of that depends
  on TLS inspection.
- This is a deliberate, scoped gap, not an oversight: the spec's TLS
  inspection deliverable is deferred, not dropped.

## Revisit when
An enterprise CA becomes available, or a compliance requirement demands
payload-level HTTPS inspection. At that point, plan together:
- Importing the intermediate CA certificate into each stamp's Key Vault.
- Adding a user-assigned managed identity to the firewall, with a Key Vault
  role assignment scoped to that certificate.
- Distributing trust of the intermediate CA to every client that traverses
  the firewall (management VMs, and any future workload identities).
- The `transportSecurity` block itself on the firewall policy.
