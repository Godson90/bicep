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

Describe 'Phase 6 documentation' {
    BeforeAll {
        $script:runbook06 = Get-Content (Get-RepoPath 'docs/runbooks/06-monitoring-and-sentinel.md') -Raw -ErrorAction SilentlyContinue
        $script:runbook00b = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
    }

    It '<_> exists' -ForEach 'docs/runbooks/06-monitoring-and-sentinel.md', 'docs/decisions/ADR-022-private-only-monitoring-and-hub-peering.md', 'docs/decisions/ADR-023-flow-log-identity-and-network-watcher.md', 'docs/decisions/ADR-024-sentinel-content-through-content-hub.md', 'docs/decisions/ADR-025-preview-api-subscription-diagnostic-setting.md' {
        Get-RepoPath $_ | Should -Exist
    }

    It 'the monitoring runbook follows the 9-section template' {
        foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
            $script:runbook06 | Should -Match ([regex]::Escape($section))
        }
    }

    It 'the monitoring runbook covers alert triage, Sentinel connectors and querying over the VPN or jump host (spec §5 Phase 6)' {
        foreach ($topic in 'Alert triage', 'Sentinel connector enablement', 'Content Hub', 'Microsoft Entra ID', 'Tenant-based Microsoft Defender for Cloud', 'Querying the workspace over the VPN or jump host', 'Live-only risks') {
            $script:runbook06 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the monitoring runbook has a triage entry for every alert rule' {
        foreach ($rule in 'firewall-health', 'firewall-snat-ports', 'app-http-5xx', 'app-health-check', 'key-vault-availability', 'key-vault-forbidden', 'vpn-p2s-connections', 'front-door-origin-health', 'front-door-waf-blocks', 'service-health') {
            $script:runbook06 | Should -Match ([regex]::Escape("``$rule``"))
        }
        $script:runbook06 | Should -Match 'backup job alert[^.]*Phase 8'
    }

    It 'the monitoring runbook sets ALERT_EMAIL on dev, dev-plan and prod' {
        foreach ($environment in 'dev', 'dev-plan', 'prod') {
            $script:runbook06 | Should -Match ([regex]::Escape("gh variable set ALERT_EMAIL --env $environment"))
        }
    }

    It 'the monitoring runbook and runbooks 00b and 01 require NetworkWatcherRG and NetworkWatcher_<region> before the identity script or deployment' {
        foreach ($text in $script:runbook06, $script:runbook00b, (Get-Content (Get-RepoPath 'docs/runbooks/01-deploy-stack.md') -Raw)) {
            $text | Should -Match ([regex]::Escape('az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true'))
            $text | Should -Match ([regex]::Escape('NetworkWatcher_<region>'))
        }
    }

    It 'the monitoring runbook covers the cross-region AMPLS path: East US network rule, West US 3 application rule with SNAT, and the private-endpoint NSG' {
        foreach ($topic in 'spoke-to-peer-azure-monitor', 'peer-spoke-to-azure-monitor', 'source address', 'AzureFirewallSubnet', '-firewall-rt') {
            $script:runbook06 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the monitoring runbook lists each unverified item as a live-only risk with a fallback' {
        $risks = $script:runbook06.Substring($script:runbook06.IndexOf('Live-only risks'))
        foreach ($risk in 'trusted services', 'Traffic Analytics', 'FQDN', '2021-05-01-preview', '2018-03-01') {
            $risks | Should -Match ([regex]::Escape($risk))
        }
        ([regex]::Matches($risks, 'Fallback')).Count | Should -BeGreaterOrEqual 5
    }

    It 'runbook 00b documents the Phase 6 grants: Network Contributor on NetworkWatcherRG and the diagnostic-setting actions with the update path' {
        foreach ($topic in 'Network Contributor', '-NetworkWatcherResourceGroupName', 'Microsoft.Insights/diagnosticSettings/write', 'az role definition update', 'Update custom role actions') {
            $script:runbook00b | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'runbook 05 and ADR-021 no longer say Application Insights stays public until Phase 6' {
        Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw | Should -Not -Match 'until Phase 6'
        Get-Content (Get-RepoPath 'docs/decisions/ADR-021-application-insights-per-region.md') -Raw | Should -Match 'ADR-022'
    }

    It 'the architecture overview, README and cost document cover Phase 6' {
        $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
        foreach ($adr in 'ADR-022', 'ADR-023', 'ADR-024', 'ADR-025') { $overview | Should -Match $adr }
        $overview | Should -Match '\*\*Phase 6\*\*'
        Get-Content (Get-RepoPath 'README.md') -Raw | Should -Match ([regex]::Escape('06-monitoring-and-sentinel.md'))
        $cost = Get-Content (Get-RepoPath 'docs/cost.md') -Raw
        $cost | Should -Match '## Phase 6 delta'
        foreach ($driver in 'Sentinel', 'Traffic Analytics', 'flow-log storage', 'private endpoint', 'DNS zones', 'peering', 'alert') {
            $cost | Should -Match ([regex]::Escape($driver))
        }
    }
}

Describe 'Phase 7 documentation' {
    BeforeAll {
        $script:runbook07 = Get-Content (Get-RepoPath 'docs/runbooks/07-governance.md') -Raw -ErrorAction SilentlyContinue
        $script:runbook03 = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
        $script:runbook06Text = Get-Content (Get-RepoPath 'docs/runbooks/06-monitoring-and-sentinel.md') -Raw
        $script:runbook00bText = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
    }

    It '<_> exists' -ForEach 'docs/runbooks/07-governance.md', 'docs/decisions/ADR-026-operator-deployed-governance-entry-point.md', 'docs/decisions/ADR-027-audit-first-policy-enforcement.md', 'docs/decisions/ADR-028-jit-access-and-nsg-ownership.md', 'docs/decisions/ADR-029-preview-apis-for-governance.md' {
        Get-RepoPath $_ | Should -Exist
    }

    It 'the governance runbook follows the 9-section template' {
        foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
            $script:runbook07 | Should -Match ([regex]::Escape($section))
        }
    }

    It 'the governance runbook covers the exemption procedure and Defender recommendation handling (spec section 5 Phase 7)' {
        foreach ($topic in 'Exemption procedure', 'Defender recommendation handling', 'Requesting JIT access', 'Live-only risks', 'az policy exemption create') {
            $script:runbook07 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the governance runbook deploys with PIM-activated operator roles, never the pipeline' {
        foreach ($topic in 'Privileged Identity Management', 'Security Admin', 'User Access Administrator', 'Owner', 'az deployment sub what-if', 'az deployment sub create', '--template-file governance.bicep --parameters params/governance.bicepparam') {
            $script:runbook07 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the governance runbook sets SECURITY_CONTACT_EMAILS before what-if and create' {
        $setAt = $script:runbook07.IndexOf('$env:SECURITY_CONTACT_EMAILS')
        $setAt | Should -BeGreaterThan 0
        $setAt | Should -BeLessThan $script:runbook07.IndexOf('az deployment sub what-if')
    }

    It 'the governance runbook deploys governance before the workload (JIT needs Defender for Servers)' {
        $script:runbook07 | Should -Match 'governance first, then the workload deploy'
        $script:runbook07.IndexOf('az deployment sub create') | Should -BeLessThan $script:runbook07.IndexOf('**Deploy the workload**')
    }

    It 'the governance runbook documents the audit-to-deny switch with the compliance review' {
        foreach ($topic in 'DoNotEnforce', "denyEnforcement = 'Default'", 'az policy state summarize', 'az policy state list', 'about a week') {
            $script:runbook07 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the governance runbook spells out the ordering trap for a new environment or region' {
        $trap = $script:runbook07.Substring($script:runbook07.IndexOf('**The ordering trap.**'))
        foreach ($step in "Set ``denyEnforcement = 'DoNotEnforce'``", 'Deploy the workload', 'Add the environment', 'Redeploy governance', "Set ``denyEnforcement = 'Default'``") {
            $trap | Should -Match ([regex]::Escape($step))
        }
    }

    It 'the governance runbook marks the legacy waiver expiry as a placeholder and clears the group after teardown' {
        $script:runbook07 | Should -Match ([regex]::Escape('`2027-03-31` is a **placeholder to confirm**'))
        $script:runbook07 | Should -Match ([regex]::Escape("legacyResourceGroupName = ''"))
    }

    It 'the governance runbook lists each unverified item as a live-only risk with a fallback' {
        $risks = $script:runbook07.Substring($script:runbook07.IndexOf('### Live-only risks'))
        foreach ($risk in 'policyExemptions@2026-01-01-preview', 'securityContacts@2023-12-01-preview', 'skips `global`', 'resource-group locations policy', 'NSG redeploy', 'action list', 'CapGBPerMonthPerStorageAccount') {
            $risks | Should -Match ([regex]::Escape($risk))
        }
        ([regex]::Matches($risks, 'Fallback')).Count | Should -BeGreaterOrEqual 6
    }

    It 'the governance runbook requests JIT access with the 2020-01-01 initiate body: one source and an end time per port' {
        $start = $script:runbook07.IndexOf('### 5.4 Requesting JIT access')
        $start | Should -BeGreaterThan 0
        $section = $script:runbook07.Substring($start, $script:runbook07.IndexOf('## 6. Validation') - $start)
        $section | Should -Match 'endTimeUtc\s*='
        $section | Should -Match 'allowedSourceAddressPrefix\s*='
        $section | Should -Match ([regex]::Escape(".ToUniversalTime().AddHours(3).ToString('yyyy-MM-ddTHH:mm:ssZ')"))
        $section | Should -Not -Match 'duration\s*='
        $section | Should -Not -Match 'allowedSourceAddressPrefixes'
    }

    It 'runbook 03 requires a JIT request before admin access' {
        $script:runbook03 | Should -Match 'Admin access now needs a JIT request first'
        $script:runbook03 | Should -Match 'ADR-028'
        $script:runbook03 | Should -Not -Match 'It is deferred to Phase 7'
    }

    It 'runbook 06 records the stfl flow-log exemption as in place' {
        $script:runbook06Text | Should -Match ([regex]::Escape('defenstack-flow-log-storage-public-network'))
        $script:runbook06Text | Should -Not -Match 'will need an exemption'
    }

    It 'runbook 00b states that the pipeline does not deploy governance and deploy.yml skips governance-only paths' {
        $script:runbook00bText | Should -Match 'The pipeline does not deploy governance'
        $script:runbook00bText | Should -Match ([regex]::Escape('modules/governance/**'))
        $script:runbook00bText | Should -Match ([regex]::Escape('params/governance.bicepparam'))
    }

    It 'ADR-014 points to its successor ADR-028' {
        Get-Content (Get-RepoPath 'docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md') -Raw | Should -Match 'Superseded by `ADR-028`'
    }

    It 'the architecture overview, README and cost document cover Phase 7' {
        $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
        foreach ($adr in 'ADR-026', 'ADR-027', 'ADR-028', 'ADR-029') { $overview | Should -Match $adr }
        $overview | Should -Match '\*\*Phase 7\*\*'
        Get-Content (Get-RepoPath 'README.md') -Raw | Should -Match ([regex]::Escape('07-governance.md'))
        $cost = Get-Content (Get-RepoPath 'docs/cost.md') -Raw
        $cost | Should -Match '## Phase 7 delta'
        foreach ($driver in 'Defender for Servers Plan 2', 'Defender for Storage', 'malware scanning', 'Defender CSPM', 'confirm on the pricing page') {
            $cost | Should -Match ([regex]::Escape($driver))
        }
    }
}
