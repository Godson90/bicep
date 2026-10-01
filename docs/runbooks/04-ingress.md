# 04 - Ingress runbook (Front Door Premium, WAF, Private Link origins, custom domain)

> Owning module(s): `modules/frontDoor.bicep`, wired by `main.bicep` (module `frontDoor`, deployed into `rg-defenstack-<env>-global` after both region stamps). Approval script: `scripts/Approve-FrontDoorPrivateEndpoints.ps1`, run by `.github/workflows/deploy.yml`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Ingress", §5 Phase 4.

## 1. Purpose and scope

This runbook makes the private App Service reachable by **public internet users**, only through Azure Front Door Premium with a WAF. App Service public network access stays `Disabled`. Front Door reaches each region's app over **Private Link**, so the app's `*.azurewebsites.net` hostname keeps refusing direct requests.

| Path | Route | Enforced by |
|---|---|---|
| User → `https://<endpoint>.azurefd.net` (or the custom domain) | Front Door edge → WAF → origin group `app` → Private Link → App Service (primary, priority 1) | WAF policy (Prevention), HTTPS redirect, TLS 1.2 minimum |
| Failover | The same, to the East US App Service (priority 2) when the primary fails its health probes (prod only) | Origin group health probes on `healthCheckPath` |
| User → `https://<app>.azurewebsites.net` | Refused (`403`) | App Service `publicNetworkAccess: Disabled` |

**Created in `rg-defenstack-<env>-global`:**
- Front Door profile `afd-defenstack-<env>`: `Premium_AzureFrontDoor`, with a system-assigned identity that is reserved for future customer-managed certificates.
- Endpoint `fde-defenstack-<env>`, whose hostname is `fde-defenstack-<env>-<hash>.z01.azurefd.net`.
- Origin group `app`:
  - Health probe: `HEAD` over HTTPS on `healthCheckPath`, every 30 s; 3 of 4 samples must succeed.
  - Origins `app-wus3` (priority 1) and, in prod, `app-eus` (priority 2). Each reaches its App Service over a `sites` Private Link with request message `defenstack-frontdoor`.
- Route `app`: `/*`; HTTP and HTTPS accepted, HTTP redirected to HTTPS; forwarded to the origin over HTTPS only.
- WAF policy `wafdefenstack<env>`:
  - **Prevention** mode in every environment, with request body inspection.
  - Managed rule sets: Microsoft Default Rule Set **2.1** (block) and Bot Manager **1.1**.
  - Custom rule `RateLimitPerClientIp`: 1000 requests per minute per client IP.
  - Optional country allow-list, empty by default (no geo-filter).
- Security policy `waf`, which binds the WAF to the endpoint and to the custom domain when one is set.
- Diagnostic setting `frontdoor-diagnostics`: access, health probe and WAF logs plus metrics, to `log-defenstack-<env>`.
- Prod only: `CanNotDelete` locks on the profile and the WAF policy.
- Custom domain, only when `customDomainHostName` is set: a Front Door-managed certificate, TLS 1.2 minimum, validated by a TXT record at the **external DNS host** (§5.1).

**Created on each App Service (region resource group):** a private endpoint connection, made by Front Door in a Microsoft-managed network. It starts **Pending**. The deploy pipeline approves it (§4 step 4). Until then, Front Door returns errors for that origin.

**Not in scope:**
- Azure DDoS Network Protection (`ADR-017`).
- Customer-managed certificates.
- Caching and rules-engine rules.
- The failover drill (runbook 08, Phase 8).
- Moving traffic off the old `defenStack` resource group (runbook 01a).

## 2. Prerequisites

- **Azure roles:**
  - The pipeline identity already has what it needs: `Contributor` on the global resource group (Front Door) and on each region resource group, where approving a connection uses `Microsoft.Web/sites/privateEndpointConnectionsApproval/action`.
  - An operator running §5 or §6 needs `Reader` on both resource group types, plus `Contributor` on the region resource group to approve by hand.
- **Provider registration (new in Phase 4):**

  ```powershell
  az provider register --namespace Microsoft.Cdn
  az provider show --namespace Microsoft.Cdn --query registrationState -o tsv
  ```

  Expected: `Registered`. Repeat the `show` until it is.
- **Tools:**
  - Azure CLI 2.90+, which includes the `az afd` commands, with the `front-door` extension for the WAF policy commands: `az extension add --name front-door --upgrade`.
  - Bicep CLI 0.47.16.
  - PowerShell 7 or 5.1.
  - `curl`.
- **Custom domain only:** permission to create TXT and CNAME records at the domain's **external DNS host**. Lower the hostname's TTL to 300 s a day before the cutover (§5.1).
- **Stack deployed:** Phase 3 (runbook 03) must be deployed to the environment, and the App Service must exist in each deployed region.

## 3. Parameters

| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `customDomainHostName` (`main.bicep`, set in `params/<env>.bicepparam`) | `''` | `''` until the domain exists | The hostname served by Front Door, for example `app.example.com`. Empty serves only the `azurefd.net` endpoint. Setting it starts the TXT validation in §5.1 |
| `healthCheckPath` (`main.bicep`) | `/` | `/` | The App Service health check path. Front Door probes the same path (`ADR-006`) |
| `rateLimitThresholdPerMinute` (`frontDoor.bicep`) | `1000` | `1000` | Requests per minute from one client IP before the WAF blocks it. Raise it only from measured traffic (§8) |
| `allowedCountryCodes` (`frontDoor.bicep`) | `[]` | `[]` | No geo-filter (user decision). A non-empty ISO list blocks every other country |
| WAF `mode` (`frontDoor.bicep`) | `Prevention` | `Prevention` | Prevention in every environment (user decision), so the §6 WAF test returns 403 in dev too |
| `enableDeleteLock` (`main.bicep`: `isProd`) | `false` | `true` | Prod locks the profile and the WAF policy |

## 4. Step-by-step deployment

1. **Register the provider** (§2) once per subscription.

2. **Validate and preview** from the repository root:

   ```powershell
   az deployment sub validate --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
   az deployment sub what-if --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
   ```

   `validate` must end with `"provisioningState": "Succeeded"`. In the what-if, check that `rg-defenstack-dev-global` creates `afd-defenstack-dev` and its `afdEndpoints`, `originGroups/origins`, `routes` and `securityPolicies` children, plus `wafdefenstackdev` and `frontdoor-diagnostics`. Expect **no changes** to the App Service, firewall or network resources in the region resource group. Stop if any region resource shows Delete or recreate.

3. **Deploy through the pipeline**: GitHub → Actions → `deploy` → **Run workflow** → environment `dev` (prod: the two-approval flow in `ADR-012`). Expect 10–20 minutes for the Front Door resources.

4. **Approval runs automatically.** After `Deploy`, a second `azure/login` step refreshes the pipeline's token (the approval wait can outlast the first one), then the job runs **Approve Front Door private endpoint connections**. It reads `appServiceIds`, `frontDoorProfileName` and `globalResourceGroupName` from the deployment outputs and calls the approval script, which:
   - waits, by default for up to 15 minutes per app, for Front Door to create its connection on each app;
   - approves a connection whose request message is `defenstack-frontdoor` only when the app has no approved Front Door connection yet and exactly one such request is pending (the message match is case-sensitive, so a different-case message is never treated as a match);
   - reports and leaves alone every other pending connection;
   - **approves nothing and fails the step** when a `defenstack-frontdoor` request is pending while a Front Door connection is already approved, or when more than one such request is pending. Anyone can put that text on a private endpoint request, so either case may be a spoofed request: follow §5.2;
   - **finishes only when Front Door's own origin reports its private link `Approved`** (read with `az afd origin list`, field `sharedPrivateLinkResource.status`), not merely when a connection is Approved. If it approved a connection but the origin never reaches `Approved` within the timeout, it fails with a distinct message, because that connection may not be the one Front Door is actually using (§5.2).

   Check: the step log shows `<app>: approved Front Door connection '<name>' (private endpoint <id>).` on the first deployment, and ends with `<app>: Front Door origin '<origin>' reports its private link Approved.` for each app.

   **Deploying from a workstation instead** (or if the step failed), run the same script by hand:

   ```powershell
   $d = az deployment sub list --query "sort_by([?properties.outputs.appServiceIds && properties.parameters.environmentName.value=='dev'], &properties.timestamp)[-1].name" -o tsv
   # Replace `dev` with `prod` for prod. If you have the Actions run, the pipeline's own deployment name,
   # `gh-<run id>-<attempt>`, is the most precise choice and skips this lookup entirely.
   $outputs = az deployment sub show --name $d --query properties.outputs -o json | ConvertFrom-Json
   ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 `
     -AppServiceId $outputs.appServiceIds.value `
     -FrontDoorProfileName $outputs.frontDoorProfileName.value `
     -FrontDoorResourceGroupName $outputs.globalResourceGroupName.value
   ```

   Preview it first with `-WhatIf`, which approves nothing and does not wait.

5. **Record the outputs:**

   ```powershell
   az deployment sub show --name $d --query "properties.outputs.{endpoint:frontDoorEndpointHostName.value, token:frontDoorCustomDomainValidationToken.value, message:frontDoorPrivateLinkRequestMessage.value}" -o table
   ```

   Expected: `endpoint` = `fde-defenstack-dev-<hash>.z01.azurefd.net`; `token` empty (no custom domain); `message` = `defenstack-frontdoor`.

6. **Wait for propagation.** A new endpoint can return `404` or `Our services aren't available right now` for up to 20 minutes after deployment. Then run §6.

## 5. Manual and post-deployment steps

### 5.1 Custom domain and DNS cutover (external DNS host)

Do this once per environment, when the domain exists. The example uses `app.example.com` and endpoint `fde-defenstack-prod-<hash>.z01.azurefd.net`.

1. **A day before:** lower the TTL of the hostname's current record to 300 seconds at the DNS host, so the cutover propagates quickly.
2. **Set the parameter** in a PR (`params/prod.bicepparam`):

   ```bicep
   param customDomainHostName = 'app.example.com'
   ```

   Deploy (§4 steps 2–4). The what-if adds `customDomains/app-example-com` and updates the route and security policy.
3. **Create the validation TXT record** at the DNS host, using the token from the outputs (§4 step 5):

   | Type | Name | Value | TTL |
   |---|---|---|---|
   | TXT | `_dnsauth.app` (FQDN `_dnsauth.app.example.com`) | the `frontDoorCustomDomainValidationToken` output | 300 |

   Check from a workstation: `Resolve-DnsName _dnsauth.app.example.com -Type TXT` returns the token.
4. **Wait for validation:**

   ```powershell
   az afd custom-domain show --profile-name afd-defenstack-prod --resource-group rg-defenstack-prod-global --custom-domain-name app-example-com --query "{validation:domainValidationState, provisioning:provisioningState}" -o table
   ```

   Expected: `validation` = `Approved`, usually within 10 minutes and up to a few hours. The token expires after 7 days. If it does, run `az afd custom-domain regenerate-validation-token ...`, update the TXT record, and wait again.
5. **Cut over:** create or replace the hostname record at the DNS host:

   | Type | Name | Value | TTL |
   |---|---|---|---|
   | CNAME | `app` | `fde-defenstack-prod-<hash>.z01.azurefd.net` | 300 |

   An **apex** domain (`example.com`) cannot have a CNAME. Use the DNS host's ALIAS, ANAME or CNAME-flattening record, pointing at the same endpoint hostname. If the host has none, serve `www` and redirect the apex at the DNS host.
6. **Check the certificate:** Front Door issues the managed certificate after the CNAME resolves, within about an hour. The certificate renews automatically; nothing to rotate.

   ```powershell
   curl.exe -sI https://app.example.com/
   ```

   Expected: `HTTP/1.1 200` (or `HTTP/2 200`), with a certificate issued to `app.example.com`.
7. Raise the TTL back (3600 s) once traffic is confirmed (§6). Keep the TXT record; Front Door may use it for revalidation.

### 5.2 Approving a private endpoint connection by hand

Use this when the pipeline step cannot run, for example when the pipeline is down.

```powershell
$appId = az webapp show --name <app> --resource-group rg-defenstack-dev-wus3 --query id -o tsv
az network private-endpoint-connection list --id $appId --query "[].{name:name, status:properties.privateLinkServiceConnectionState.status, message:properties.privateLinkServiceConnectionState.description}" -o table
```

Approve only rows whose `message` is `defenstack-frontdoor`. Keep that text as the start of the description, so the script and §6 still recognize the connection afterwards:

```powershell
az network private-endpoint-connection approve --id "$appId/privateEndpointConnections/<name>" --description "defenstack-frontdoor approved manually by <you>"
```

**Confirm Front Door's own view afterwards**, the same thing the script waits for:

```powershell
az afd origin show --profile-name afd-defenstack-dev --resource-group rg-defenstack-dev-global --origin-group-name app --origin-name app-wus3 --query sharedPrivateLinkResource.status -o tsv
```

If it still shows `Pending` a few minutes after you approved, the connection you approved is not Front Door's: reject it immediately and treat it as a security incident (see item 1 below). Approving a connection in the portal without the `defenstack-frontdoor` prefix is fine now, because the script (and this check) trust the origin's status, not the connection's description — but prefer running the script, which does this check for you.

**The request message is not proof.** Whoever creates a private endpoint chooses its request message, so a third party can also send `defenstack-frontdoor`. This is why the script refuses to choose between several matching requests, or to approve one while Front Door's connection is already approved. When the step fails that way:

1. If a Front Door connection is already `Approved` and the origin is healthy (the §6 origin health row shows `100`), Front Door does not need another one. Reject every pending matching request: `az network private-endpoint-connection reject --id "$appId/privateEndpointConnections/<name>" --description "unexpected request"`. Then raise a security incident and re-run the pipeline.
2. If several matching requests are pending and none is approved (a first deployment), you cannot tell which one is Front Door's. Reject them all. Then delete and recreate the origin so that Front Door sends a fresh request: `az afd origin delete --profile-name afd-defenstack-<env> --resource-group rg-defenstack-<env>-global --origin-group-name app --origin-name app-<regionCode> --yes`, then redeploy. If more than one matching request appears again, treat it as an incident. Prod: the profile's `CanNotDelete` lock blocks deleting the origin (`ScopeLocked`). Delete the lock first (`az lock list -g rg-defenstack-prod-global -o table`, then `az lock delete --ids <id>`); the next deployment recreates it.
3. Record the approved connection's private endpoint ID from the step log (`(private endpoint <id>)`) in the PR. Compare later approvals against it.

**Never approve a pending connection with any other message.** Nothing in this project creates one, so it is an unknown party asking for private access to the app. Reject it (`az network private-endpoint-connection reject --id ... --description "unexpected request"`) and raise a security incident.

### 5.3 WAF tuning and exclusions

1. **Find what the WAF blocked** (workspace `log-defenstack-<env>`):

   ```kusto
   AzureDiagnostics
   | where Category == "FrontDoorWebApplicationFirewallLog" and TimeGenerated > ago(24h)
   | where action_s in ("Block", "AnomalyScoring")
   | summarize hits = count() by ruleName_s, requestUri_s, clientIP_s
   | order by hits desc
   ```

2. **Decide.** A hit is a false positive only when the request is legitimate application traffic. Scanners and probes are expected hits; leave them blocked.
3. **Fix the narrowest thing first, through a PR to `modules/frontDoor.bicep`:**
   - **Exclusion** (preferred): stop inspecting one named request element for one rule set. Add it to the `Microsoft_DefaultRuleSet` entry:

     ```bicep
     exclusions: [
       {
         matchVariable: 'RequestBodyPostArgNames'
         selectorMatchOperator: 'Equals'
         selector: 'comment'
       }
     ]
     ```

   - **Rule override** (only when an exclusion cannot express it): set one rule to `Log`:

     ```bicep
     ruleGroupOverrides: [
       {
         ruleGroupName: 'SQLI'
         rules: [
           {
             ruleId: '942440'
             enabledState: 'Enabled'
             action: 'Log'
           }
         ]
       }
     ]
     ```

   - Never switch the whole policy to `Detection`, and never disable a rule set, to fix one false positive.
4. Validate, check the what-if, deploy through the pipeline, then repeat the step 1 query. The hit must now show `action_s == "Log"` or disappear.
5. Record every exclusion and override in the PR description: the rule ID, the request, and why it is safe.

## 6. Validation

Run from any internet-connected workstation. `$fd` is the endpoint hostname from §4 step 5.

| Check | Command | Expected result |
|---|---|---|
| Front Door serves the app | `curl.exe -s -o NUL -w "%{http_code}" https://$fd/` | `200` |
| HTTP redirects to HTTPS | `curl.exe -s -o NUL -w "%{http_code} %{redirect_url}" http://$fd/` | `307 https://$fd/` (a 3xx to the HTTPS URL) |
| WAF blocks an attack payload | `curl.exe -s -o NUL -w "%{http_code}" "https://$fd/?q=<script>alert(1)</script>"` | `403` |
| WAF logged the block | KQL: `AzureDiagnostics \| where Category == "FrontDoorWebApplicationFirewallLog" and TimeGenerated > ago(1h) and action_s in ("Block","AnomalyScoring") \| project TimeGenerated, ruleName_s, requestUri_s` | A row for the `?q=<script>` request |
| Direct App Service access is refused | `curl.exe -s -o NUL -w "%{http_code}" https://<app>.azurewebsites.net/` | `403` |
| Private Link connection approved | `az network private-endpoint-connection list --id $appId --query "[].properties.privateLinkServiceConnectionState.{status:status, message:description}" -o table` | `Approved`, with a message starting `defenstack-frontdoor`; no `Pending` rows |
| Origins and priorities | `az afd origin list --profile-name afd-defenstack-dev --resource-group rg-defenstack-dev-global --origin-group-name app --query "[].{name:name, priority:priority, enabled:enabledState, privateLink:sharedPrivateLinkResource.status}" -o table` | `app-wus3`, priority `1`, `Enabled`, `Approved` (prod adds `app-eus`, priority `2`) |
| Origin health | `az monitor metrics list --resource $(az afd profile show -n afd-defenstack-dev -g rg-defenstack-dev-global --query id -o tsv) --metric OriginHealthPercentage --interval PT5M --query "value[0].timeseries[0].data[-1].average"` | `100` |
| WAF policy settings | `az network front-door waf-policy show -n wafdefenstackdev -g rg-defenstack-dev-global --query "{mode:policySettings.mode, sets:managedRules.managedRuleSets[].[ruleSetType, ruleSetVersion]}" -o json` | `"mode": "Prevention"`; `sets` lists `["Microsoft_DefaultRuleSet", "2.1"]` and `["Microsoft_BotManagerRuleSet", "1.1"]` |
| Logs arrive | KQL: `AzureDiagnostics \| where Category == "FrontDoorAccessLog" and TimeGenerated > ago(1h) \| summarize count() by httpStatusCode_s` (confirm the column suffix in dev; Front Door logs it as a string) | `200`, `403` and `307` rows from the checks above |
| Custom domain (when set) | `az afd custom-domain show ... --query "{validation:domainValidationState, tls:tlsSettings.minimumTlsVersion}" -o table` and `Resolve-DnsName app.example.com` | `Approved`, `TLS12`; the name resolves through a CNAME to `$fd` |

Paste every output into the Phase 4 PR (spec §6 definition of done).

## 7. Rollback

- **Remove the custom domain:**
  1. Point the CNAME back at the previous target, if one existed, so users never hit a dead name.
  2. Set `customDomainHostName = ''` and redeploy, which detaches the domain from the route and the security policy.
  3. Delete the domain resource, because incremental deployments do not delete it: `az afd custom-domain delete --profile-name afd-defenstack-<env> --resource-group rg-defenstack-<env>-global --custom-domain-name <name> --yes`. Prod: the profile's `CanNotDelete` lock blocks this (`ScopeLocked`). Delete the lock first (`az lock list -g rg-defenstack-prod-global -o table`, then `az lock delete --ids <id>`); the next deployment recreates it.
- **Take public ingress down entirely**, which makes the app private-only again:
  1. In prod, delete the two locks (`az lock list -g rg-defenstack-prod-global -o table`, then `az lock delete --ids <id>`); the next deployment recreates them.
  2. Run `az afd profile delete --profile-name afd-defenstack-<env> --resource-group rg-defenstack-<env>-global` and `az network front-door waf-policy delete -n wafdefenstack<env> -g rg-defenstack-<env>-global`.
  3. Deleting the profile removes Front Door's private endpoints. Each App Service connection becomes `Disconnected`. Delete those with `az network private-endpoint-connection delete --id <connection id>`.
  4. A later deployment of a Phase 4 commit recreates everything. The new endpoint gets a **new hash**, so update any CNAME.
- **Revert a WAF change:** revert the PR and redeploy. WAF policy updates apply within minutes, without downtime.

## 8. Operations

- **WAF tuning:** follow §5.3. Review the step 1 query weekly in dev and after every application release in prod.
- **Rule set upgrades:** when Microsoft publishes a newer Default Rule Set, raise `ruleSetVersion` in a PR, deploy to dev, and run §5.3 for a week before prod. Existing exclusions carry over; overrides may need new rule IDs.
- **Rate limit:** to size `rateLimitThresholdPerMinute`, check the busiest legitimate client: `AzureDiagnostics | where Category == "FrontDoorAccessLog" | summarize perMinute = count() by clientIp_s, bin(TimeGenerated, 1m) | summarize max(perMinute) by clientIp_s | top 10 by max_perMinute`. Keep the limit well above that.
- **Adding a region:** a new stamp adds an origin automatically (`main.bicep` origins), and the pipeline approves its connection.
- **Approval wait:** the script waits up to 15 minutes **per app**, so a first deployment with two regions can hold the job for up to 30 minutes before failing.
- **Failover:** traffic moves to the priority 2 origin when the primary fails its health probes. The drill and RTO measurement are in runbook 08 (Phase 8).
- **Certificates:** managed certificates renew automatically. Nothing to rotate. Check `az afd custom-domain show ... --query tlsSettings` quarterly.
- **Cost drivers** (`docs/cost.md` "Phase 4 delta"): the Premium base fee per profile per month, requests, and data transfer out from the edge. WAF managed rules and Private Link origins are included in Premium.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| `Our services aren't available right now` or `404` right after the first deployment | The endpoint and route are still propagating to the edge | Wait up to 20 minutes, then re-run §6 |
| `502` / `504`, or the origin health metric at `0` | The Private Link connection is still `Pending` (not approved), or the App Service is stopped | Check the §6 Private Link row. Run the approval script (§4 step 4); start the app |
| Pipeline step fails with `no Front Door private endpoint connection was approved within 900 seconds` | Front Door had not created its connection yet, or the origin failed to provision | `az afd origin show ... --query sharedPrivateLinkResource`, then re-run the script by hand (§4 step 4). If the origin shows `Failed`, redeploy |
| Pipeline step: `AuthorizationFailed ... privateEndpointConnectionsApproval/action` | The pipeline identity lacks `Contributor` on the region resource group | Re-run the identity script (runbook 00b §4) |
| Approval script warns `leaving pending connection ... not a Front Door request` | An unexpected private endpoint request on the app | Follow §5.2: reject it and raise a security incident |
| Pipeline step fails with `a Front Door connection is already approved, but a pending connection with the same request message ... also exists` | Someone sent a private endpoint request carrying Front Door's request message after Front Door's connection was approved: a possible spoofed request | §5.2 step 1: reject the pending request(s), raise an incident, re-run |
| Pipeline step fails with `multiple pending connections share the request message` | More than one request carries Front Door's message before any approval, so the real one cannot be told apart | §5.2 step 2: reject them all, recreate the origin, redeploy |
| Pipeline step fails with `did not bring Front Door's origin ... to Approved ... it may not be Front Door's request` | The script approved a connection, but Front Door's origin never reported `sharedPrivateLinkResource.status` as `Approved` within the timeout: the connection it approved may not be Front Door's | §5.2: reject the connection named in the message and treat it as a security incident |
| Pipeline step fails with `no Front Door origin in <profile>/<originGroup> references this App Service` | No origin in the origin group has a `sharedPrivateLinkResource.privateLink.id` matching this app, so Front Door never created a request for it | Check the origin exists (`az afd origin list ...`); if missing or misconfigured, redeploy |
| `MissingSubscriptionRegistration ... Microsoft.Cdn` | Provider not registered | §2 |
| `403` for legitimate requests; the WAF log shows `Block` | WAF false positive | §5.3 |
| `429` or `403` from `RateLimitPerClientIp` for a legitimate client | The client exceeds 1000 requests per minute (shared NAT, load test) | Raise `rateLimitThresholdPerMinute` from measured traffic (§8) |
| Custom domain stuck on `Pending` | The TXT record is missing or wrong, the token expired after 7 days, or the DNS host appended the zone twice (`_dnsauth.app.example.com.example.com`) | Check it with `Resolve-DnsName -Type TXT`; regenerate the token (§5.1 step 4) |
| Custom domain `Approved`, but the certificate is still `Pending` | The CNAME does not point at the endpoint yet | §5.1 step 5; wait up to an hour |
| Direct `https://<app>.azurewebsites.net` returns `200` | Someone set the App Service's `publicNetworkAccess` to `Enabled` | Redeploy; the template sets `Disabled`. Find out who changed it from the Activity Log |
| `curl` to the endpoint shows an old certificate or the old site after the cutover | The client resolver still holds the old TTL | Wait out the TTL; check with `Resolve-DnsName -Server 1.1.1.1` |
