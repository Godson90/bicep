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
        $script:runbook06 | Should -Match ([regex]::Escape('apr-defenstack-<env>-backup'))
        $script:runbook06 | Should -Not -Match 'deferred to Phase 8'
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

Describe 'Phase 8 documentation' {
    BeforeAll {
        $script:runbook08 = Get-Content (Get-RepoPath 'docs/runbooks/08-dr-failover.md') -Raw -ErrorAction SilentlyContinue
        $script:runbook00bPhase8 = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
        $script:runbook05Phase8 = Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw
        $script:adr030 = Get-Content (Get-RepoPath 'docs/decisions/ADR-030-backup-vaults-immutability-and-lock-later.md') -Raw -ErrorAction SilentlyContinue
        $script:adr031 = Get-Content (Get-RepoPath 'docs/decisions/ADR-031-blob-vaulted-backup.md') -Raw -ErrorAction SilentlyContinue
        $script:adr032 = Get-Content (Get-RepoPath 'docs/decisions/ADR-032-failover-entry-point-and-pipeline-freeze.md') -Raw -ErrorAction SilentlyContinue
    }

    It '<_> exists' -ForEach 'docs/runbooks/08-dr-failover.md', 'docs/decisions/ADR-030-backup-vaults-immutability-and-lock-later.md', 'docs/decisions/ADR-031-blob-vaulted-backup.md', 'docs/decisions/ADR-032-failover-entry-point-and-pipeline-freeze.md', 'docs/decisions/ADR-033-recovery-services-vault-public-access-for-cross-region-restore.md' {
        Get-RepoPath $_ | Should -Exist
    }

    It 'the DR runbook follows the 9-section template' {
        foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
            $script:runbook08 | Should -Match ([regex]::Escape($section))
        }
    }

    It 'the DR runbook states RTO 1 hour and RPO 15 minutes and how each is met' {
        $script:runbook08 | Should -Match '\*\*RTO\*\*[^\n]*\*\*1 hour\*\*'
        $script:runbook08 | Should -Match '\*\*RPO\*\*[^\n]*\*\*15 minutes\*\*'
        $script:runbook08 | Should -Match 'Last Sync Time'
    }

    It 'the failover procedure runs in order: declare, storage, freeze and Front Door, workspace, failover.bicep, endpoint approvals, Key Vault, verify' {
        $steps = @(
            '1. **Declare the outage**',
            '2. **Storage: fail the primary account over to East US (unplanned).**',
            '3. **Freeze the pipeline and disable the West US 3 Front Door origin.**',
            '4. **Log Analytics workspace switchover.**',
            '5. **Run `failover.bicep`.**',
            '6. **Private endpoint connections and storage writes from East US.**',
            '7. **Key Vault: no action.**',
            '8. **Verify**'
        )
        $previous = -1
        foreach ($step in $steps) {
            $at = $script:runbook08.IndexOf($step)
            $at | Should -BeGreaterThan $previous -Because $step
            $previous = $at
        }
    }

    It 'the storage failover removes the object replication policy first, then reads the Last Sync Time and fails over, before the freeze and Front Door' {
        $start = $script:runbook08.IndexOf('2. **Storage: fail the primary account over to East US (unplanned).**')
        $start | Should -BeGreaterThan 0
        $procedure = $script:runbook08.Substring($start)
        $markers = @(
            'az dataprotection backup-instance suspend-backup',
            'az storage account or-policy delete',
            '--expand geoReplicationStats',
            '--failover-type Unplanned',
            'gh workflow disable deploy',
            '--origin-name app-wus3 --enabled-state Disabled'
        )
        $previous = -1
        foreach ($marker in $markers) {
            $at = $procedure.IndexOf($marker)
            $at | Should -BeGreaterThan $previous -Because $marker
            $previous = $at
        }
        $declare = $script:runbook08.IndexOf('1. **Declare the outage**')
        $step1 = $script:runbook08.Substring($declare, $start - $declare)
        $step1 | Should -Not -Match 'az storage account list'
        $step1 | Should -Match ([regex]::Escape('$st = ''<recorded prod primary account name'))
    }

    It 'the DR runbook records the account name and ID in steady state, and has an owner-run pre-production OR failover test' {
        $begin = $script:runbook08.IndexOf('## 2. Prerequisites')
        $prerequisites = $script:runbook08.Substring($begin, $script:runbook08.IndexOf('## 3. Parameters') - $begin)
        $prerequisites | Should -Match ([regex]::Escape('**The prod primary account''s name and ID are recorded**'))
        $prerequisites | Should -Match ([regex]::Escape('### Pre-production validation (owner, sandbox only)'))
        foreach ($topic in 'never in prod', 'az storage account or-policy create', '--failover-type Unplanned', 'az group delete -n rg-dr-or-test', '`ADR-031`', 'privateEndpointConnectionsApproval/action') {
            $prerequisites | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the DR runbook splits the RTO: 1 hour for reads, about 75-90 minutes for writes, and asks the owner to confirm' {
        $script:runbook08 | Should -Match '\*\*RTO\*\*[^\n]*read serving[^\n]*\*\*Writes: expected around 75.{1,3}90 minutes\*\*'
        $script:runbook08 | Should -Match ([regex]::Escape('**Owner decision pending: confirm the write RTO.**'))
        $script:runbook08 | Should -Match ([regex]::Escape('**no secondary endpoint**'))
        $script:runbook08 | Should -Match ([regex]::Escape('the primary hostname `<st>.blob.core.windows.net`'))
    }

    It 'the DR runbook creates a temporary verification VM in the East US management subnet and deletes it at failback' {
        $start = $script:runbook08.IndexOf('8. **Verify**')
        $verify = $script:runbook08.Substring($start, $script:runbook08.IndexOf('## 5. Manual and post-deployment steps') - $start)
        foreach ($topic in 'az vm create -g rg-defenstack-prod-eus', '--subnet management', '--vnet-name vnet-defenstack-prod-eus-spoke', '--public-ip-address ''""''', '--nsg ''""''', 'AADSSHLoginForLinux', '22_04-lts-gen2', 'Standard_B2s', 'az network bastion ssh --name bas-defenstack-prod-eus', 'Phase 7 policies', 'AppRequests', 'POST|PUT|PATCH|DELETE') {
            $verify | Should -Match ([regex]::Escape($topic))
        }
        $failback = $script:runbook08.Substring($script:runbook08.IndexOf('### 5.2 Failback (planned)'))
        $failback | Should -Match ([regex]::Escape('az vm delete -g rg-defenstack-prod-eus -n vmeusdrcheck --yes'))
    }

    It 'the failover procedure uses the documented commands and re-enables geo-redundancy after the unplanned failover' {
        foreach ($command in '--enabled-state Disabled', '--expand geoReplicationStats', '--failover-type Unplanned', '--sku Standard_RAGRS', 'az monitor log-analytics workspace failover', 'at least 24 hours', '--template-file failover.bicep --parameters params/failover.bicepparam', 'az deployment sub what-if --location eastus', './scripts/Approve-FrontDoorPrivateEndpoints.ps1', 'sharedPrivateLinkResource.status') {
            $script:runbook08 | Should -Match ([regex]::Escape($command))
        }
    }

    It 'the DR runbook freezes the pipeline during DR' {
        $script:runbook08 | Should -Match '### 5\.1 Pipeline freeze during DR'
        $script:runbook08 | Should -Match ([regex]::Escape('gh workflow disable deploy'))
        $script:runbook08 | Should -Match ([regex]::Escape('gh workflow enable deploy'))
    }

    It 'the failback runs in order: check backup and OR, disable PITR and change feed, planned failover, RA-GZRS conversion, zone locks, endpoint and record, resume backup, pipeline, workspace, AMPLS endpoint, scale down, origin, lift the freeze' {
        $start = $script:runbook08.IndexOf('### 5.2 Failback (planned)')
        $start | Should -BeGreaterThan 0
        $failback = $script:runbook08.Substring($start)
        $markers = @(
            'az dataprotection backup-instance suspend-backup',
            'az storage account or-policy delete',
            '--enable-restore-policy false --enable-change-feed false',
            '--failover-type Planned',
            'az storage account migration show',
            "az lock list -g rg-defenstack-prod-global --query ""[?name=='blob-zone-lck'",
            'az lock delete --ids',
            'az role assignment delete --assignee $eusPrincipal --role "Storage Blob Data Contributor"',
            'az network private-endpoint delete -g rg-defenstack-prod-eus -n "$st-eus-pe"',
            'az network private-dns record-set a add-record -g rg-defenstack-prod-global -z privatelink.blob.core.windows.net -n $st -a $peIp',
            '--enable-change-feed true',
            'az dataprotection backup-instance resume-protection',
            'gh workflow run deploy',
            'az network private-dns record-set a show -g rg-defenstack-prod-global -z privatelink.blob.core.windows.net -n $st',
            'az monitor log-analytics workspace failback',
            'az network private-endpoint delete -g rg-defenstack-prod-eus -n ampls-defenstack-prod-eus-pe',
            'az vm delete -g rg-defenstack-prod-eus -n vmeusdrcheck',
            'az network bastion delete',
            '--origin-name app-wus3 --enabled-state Enabled',
            '9. **Lift the freeze.**'
        )
        $previous = -1
        foreach ($marker in $markers) {
            $at = $failback.IndexOf($marker)
            $at | Should -BeGreaterThan $previous -Because $marker
            $previous = $at
        }
    }

    It 'the DR runbook takes the East US blob endpoint from failover.bicep and keeps only the write grant manual (ADR-020)' {
        $script:runbook08 | Should -Match ([regex]::Escape('the blob endpoint `<st>-eus-pe`'))
        $script:runbook08 | Should -Match ([regex]::Escape('| `primaryStorageAccountId` |'))
        $script:runbook08 | Should -Match ([regex]::Escape('**Create** `<st>-eus-pe` and its zone group `default` (blob).'))
        $start = $script:runbook08.IndexOf('6. **Private endpoint connections and storage writes from East US.**')
        $step6 = $script:runbook08.Substring($start, $script:runbook08.IndexOf('7. **Key Vault: no action.**') - $start)
        $step6 | Should -Match ([regex]::Escape('**The grant is the one manual step.**'))
        ([regex]::Matches($step6, 'az role assignment create')).Count | Should -Be 1
        $step6 | Should -Match ([regex]::Escape('--role "Storage Blob Data Contributor" --scope "$stId/blobServices/default/containers/def-blob"'))
        $step6 | Should -Not -Match 'az network private-endpoint create'
        $step6 | Should -Not -Match 'dns-zone-group create'
        $script:runbook08 | Should -Not -Match 'dr-pe'
    }

    It 'the DR runbook covers restores: VM cross-region restore and blob vaulted restore to another account, with no blob cross-region restore' {
        foreach ($topic in '### 5.4 Restores', '--use-secondary-region', 'az backup restore restore-disks', 'initialize-for-item-recovery', '--source-datastore VaultStore', '**no cross-region restore for blobs**') {
            $script:runbook08 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the DR runbook has the quarterly drill, the drill log table and the irreversible hardening with an ADR sign-off' {
        $script:runbook08 | Should -Match 'Quarterly drill'
        $script:runbook08 | Should -Match ([regex]::Escape('| Date | Type (drill / real) | RTO measured | RPO measured | Issues | Sign-off |'))
        foreach ($topic in '--immutability-state Locked', '--soft-delete-feature-state AlwaysON', '--soft-delete-state AlwaysOn', 'sign-off recorded in `ADR-030`') {
            $script:runbook08 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the DR runbook has backup alert triage through the alert processing rule' {
        $script:runbook08 | Should -Match '### 5\.5 Backup alert triage'
        $script:runbook08 | Should -Match ([regex]::Escape('apr-defenstack-<env>-backup'))
    }

    It 'the DR runbook lists each unverified item as a live-only risk with a fallback' {
        $risks = $script:runbook08.Substring($script:runbook08.IndexOf('### Live-only risks'))
        foreach ($risk in "publicNetworkAccess: 'Disabled'", 'Private link after the workspace switchover', 'Bastion deploy time', 'The global resource group lives in westus3', 'RBAC race', 'container discovery', 'Cross-region restore storage settings', 'crossRegionRestoreFlag', 'Resuming blob backup before the failback pipeline run', 'Vaulted-only blob policy', 'bastion-diagnostics', 'deploy once', 'unverified', 'hosts-file', 'conditional forwarder', 'The blob record after failback', 'privatelink.blob.core.windows.net -n $st', 'dns-zone-group delete -g rg-defenstack-prod-wus3 --endpoint-name "$st-pe"', 'The blob endpoint during the storage failover') {
            $risks | Should -Match ([regex]::Escape($risk))
        }
        ([regex]::Matches($risks, '\*\*Fallback:\*\*')).Count | Should -BeGreaterOrEqual 7
    }

    It 'the DR runbook never locks AzureBackupRG and stops protection by hand when the jump host goes' {
        $script:runbook08 | Should -Match ([regex]::Escape('Never lock `AzureBackupRG_<region>_1`'))
        $script:runbook08 | Should -Match ([regex]::Escape('az backup protection disable'))
    }

    It 'the DR runbook cites Microsoft Learn for platform behaviour' {
        ([regex]::Matches($script:runbook08, 'https://learn\.microsoft\.com/')).Count | Should -BeGreaterOrEqual 10
    }

    It 'ADR-033 keeps public network access Enabled for cross-region restore, quoting the FAQ and stating the trade-off' {
        $adr033 = Get-Content (Get-RepoPath 'docs/decisions/ADR-033-recovery-services-vault-public-access-for-cross-region-restore.md') -Raw
        foreach ($topic in '**`publicNetworkAccess: ''Enabled''`**', 'Without a private connection in the secondary region, CRR can''t perform the required replication', 'https://learn.microsoft.com/azure/backup/backup-azure-backup-faq', 'snapshot-based', '**The trade-off:**', 'Verify it in the first drill') {
            $adr033 | Should -Match ([regex]::Escape($topic))
        }
        Get-RepoPath 'docs/decisions/ADR-033-recovery-services-vault-public-access-denied-without-private-endpoint.md' | Should -Not -Exist
        $script:runbook08 | Should -Not -Match ([regex]::Escape('Recovery Services vault with public access denied'))
    }

    It 'stopping protection does not delete the object replication policy (support matrix), in ADR-031, runbook 05 and the runbook 08 rollback' {
        $script:adr031 | Should -Match ([regex]::Escape('**Stopping protection does not delete the object replication policy**'))
        $script:runbook05Phase8 | Should -Match ([regex]::Escape('**Stopping protection does not delete the object replication policy**'))
        $script:runbook05Phase8 | Should -Not -Match ([regex]::Escape('Stopping protection** removes the object replication policy'))
        $begin = $script:runbook08.IndexOf('## 7. Rollback')
        $rollback = $script:runbook08.Substring($begin, $script:runbook08.IndexOf('## 8. Operations') - $begin)
        $rollback | Should -Match ([regex]::Escape('az storage account or-policy delete'))
    }

    It 'ADR-031 and runbook 00b record the pipeline identity''s reach through the delegated backup role' {
        foreach ($topic in 'including to itself', 'lock management', 'Optional tightening, not applied', 'Pre-production validation') {
            $script:adr031 | Should -Match ([regex]::Escape($topic))
        }
        $script:runbook00bPhase8 | Should -Match ([regex]::Escape('**including itself**'))
    }

    It 'the diagnostic-settings audit gap for the backup vaults is recorded as a follow-up, without changing governance' {
        $script:adr030 | Should -Match ([regex]::Escape('Microsoft.DataProtection/backupVaults'))
        Get-Content (Get-RepoPath 'docs/runbooks/07-governance.md') -Raw | Should -Match ([regex]::Escape('**Follow-up from Phase 8 (not yet done):**'))
        Get-Content (Get-RepoPath 'governance.bicep') -Raw | Should -Not -Match 'Microsoft\.RecoveryServices/vaults' -Because 'this pins the recorded follow-up in ADR-030: once the vault types are added to the diagnostic audit in governance.bicep, this assertion must be updated (to check the types are present) or removed'
    }

    It 'ADR-030 justifies the Azure.RSV.ReplicationAlert exclusion that ps-rule.yaml carries' {
        $script:adr030 | Should -Match ([regex]::Escape('Azure.RSV.ReplicationAlert'))
        $script:adr030 | Should -Match 'Locked'
        Get-Content (Get-RepoPath 'ps-rule.yaml') -Raw | Should -Match '# ADR-030:'
    }

    It 'ADR-031 records the datasource type, the wrong Adls correction and the effects on the protected account' {
        foreach ($topic in 'BlobBackupDatasourceParameters', 'AdlsBlobBackupDatasourceParameters', 'That correction was wrong', 'BCP036', 'Effects on backed-up storage accounts', 'change feed and delete lock', 'No conflict in this repository', 'no cross-region restore', 'new policy name') {
            $script:adr031 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'ADR-032 records the failover entry point, the pipeline freeze and the global resource group risk as unverified' {
        foreach ($topic in 'failover.bicep', 'Pipeline freeze', 'westus3', 'unverified', 'conditional-forwarder', '**temporary verification VM**', '**no secondary endpoint**') {
            $script:adr032 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'ADR-032 records the East US blob endpoint, the West US 3 reference-only rule and the manual write grant' {
        foreach ($topic in '`<account>-eus-pe`', 'modules/failover/storagePrivateEndpoint.bicep', '`primaryStorageAccountId`', 'uniqueString(subscription().id, ''prod'', ''westus3'')', '**Nothing targets West US 3.**', '`privateLinkServiceId`', '**The write role stays a manual, PIM-gated runbook step, outside Bicep.**', '**Storage Blob Data Contributor**', '`ADR-020`') {
            $script:adr032 | Should -Match ([regex]::Escape($topic))
        }
        $script:adr032 | Should -Not -Match 'the build contains no'
    }

    It 'runbook 00b adds the Storage Account Backup Contributor role and asks for an identity script re-run before Phase 8' {
        $script:runbook00bPhase8 | Should -Match 'e5e2a7ff-d759-4cd2-bb51-3152d37e2eb1'
        $script:runbook00bPhase8 | Should -Match 're-run the identity script before the first Phase 8 deploy'
        $script:runbook00bPhase8 | Should -Match ([regex]::Escape('The pipeline does not run `failover.bicep`'))
    }

    It 'runbook 05 points blob backup and the account failover to runbook 08 and documents the backup effects' {
        $script:runbook05Phase8 | Should -Match ([regex]::Escape('08-dr-failover.md'))
        $script:runbook05Phase8 | Should -Match 'blob vaulted backup'
        $script:runbook05Phase8 | Should -Match 'Effects of blob vaulted backup'
        $script:runbook05Phase8 | Should -Not -Match 'belongs to the DR runbook \(Phase 8\)'
    }

    It 'runbook 01 sends failover to runbook 08 instead of scaling by hand' {
        $text = Get-Content (Get-RepoPath 'docs/runbooks/01-deploy-stack.md') -Raw
        $text | Should -Match ([regex]::Escape('08-dr-failover.md'))
        $text | Should -Not -Match 'lands in Phase 8'
    }

    It 'runbook 07 says the allowlist already covers the East US Bastion IP' {
        Get-Content (Get-RepoPath 'docs/runbooks/07-governance.md') -Raw | Should -Match ([regex]::Escape('pip-bas-defenstack-prod-eus'))
    }

    It 'the architecture overview, README and cost document cover Phase 8' {
        $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
        foreach ($adr in 'ADR-030', 'ADR-031', 'ADR-032', 'ADR-033') { $overview | Should -Match $adr }
        $overview | Should -Match '\*\*Phase 8\*\*'
        Get-Content (Get-RepoPath 'README.md') -Raw | Should -Match ([regex]::Escape('08-dr-failover.md'))
        $cost = Get-Content (Get-RepoPath 'docs/cost.md') -Raw
        $cost | Should -Match '## Phase 8 delta'
        $cost | Should -Match ([regex]::Escape('Blob private endpoint `<primary account>-eus-pe` in East US'))
        foreach ($driver in 'protected instance', 'GRS', 'Backup vault', 'Object replication', 'Bastion', 'P2V3', 'confirm on the pricing page') {
            $cost | Should -Match ([regex]::Escape($driver))
        }
        $phase8 = $cost.Substring($cost.IndexOf('## Phase 8 delta'), $cost.IndexOf('## Dominant future cost drivers') - $cost.IndexOf('## Phase 8 delta'))
        $phase8 | Should -Not -Match '\$\s?\d'
    }

    It 'the DR runbook installs the Azure CLI on the verification VM with the apt method, not the blocked one-line installer' {
        $start = $script:runbook08.IndexOf('8. **Verify**')
        $verify = $script:runbook08.Substring($start, $script:runbook08.IndexOf('## 5. Manual and post-deployment steps') - $start)
        foreach ($topic in 'aka.ms', 'azurecliprod.blob.core.windows.net', 'packages.microsoft.com/keys/microsoft.asc', 'sudo apt-get install -y azure-cli', 'management.azure.com') {
            $verify | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the DR runbook adds a temporary, dated firewall rule for the verification VM and deletes it at failback and drill clean-up' {
        $script:runbook08 | Should -Match ([regex]::Escape('dr-verification-temp'))
        $script:runbook08 | Should -Match ([regex]::Escape('az network firewall policy rule-collection-group create -g rg-defenstack-prod-eus --policy-name $eusPolicy -n dr-verification-temp --priority 900'))
        $script:runbook08 | Should -Match ([regex]::Escape('dated, manual exception'))
        $failback = $script:runbook08.Substring($script:runbook08.IndexOf('### 5.2 Failback (planned)'))
        $failback | Should -Match ([regex]::Escape('az network firewall policy rule-collection-group delete -g rg-defenstack-prod-eus --policy-name afwp-defenstack-prod-eus -n dr-verification-temp'))
        $script:runbook08 | Should -Match ([regex]::Escape('its temporary `dr-verification-temp` firewall rule and the East US Bastion are gone'))
        $script:runbook08 | Should -Match ([regex]::Escape('If the rule cannot be added'))
    }

    It 'the DR runbook quotes both Microsoft sources on the fail-back-then-convert order and corrects the RA-GRS vs RA-GZRS wording for both paths' {
        foreach ($quote in 'they need to perform a failback operation', "Conversion to ZRS or GZRS for an LRS account resulting from a failover isn't supported. Instead, perform a manual migration to add zone-redundancy.") {
            $script:runbook08 | Should -Match ([regex]::Escape($quote))
        }
        foreach ($url in 'https://learn.microsoft.com/azure/storage/common/storage-failover-faq', 'https://learn.microsoft.com/azure/storage/common/redundancy-migration#failover-and-failback') {
            $script:runbook08 | Should -Match ([regex]::Escape($url))
        }
        $script:runbook08 | Should -Match ([regex]::Escape('After a real unplanned failover'))
        $script:runbook08 | Should -Match ([regex]::Escape('After a planned drill failover'))
        $script:runbook08 | Should -Match ([regex]::Escape('the account is `Standard_RAGRS` here, and step 3.2 converts it to `Standard_RAGZRS`'))
        $script:runbook08 | Should -Match ([regex]::Escape('The account is still `Standard_RAGZRS` here, and step 3.2 is a no-op check'))
    }

    It 'the DR runbook and ADR-020 restore a real fallback for a refused or slow RA-GZRS conversion, time-boxed before the hotfix' {
        foreach ($topic in 'Open a Microsoft support request for the conversion', 'Ship a time-boxed hotfix pull request', 'Standard_RAGRS` — the line `storageAccountSkuName', 'for example **24 hours**', 'There''s no SLA for completion of a conversion') {
            $script:runbook08 | Should -Match ([regex]::Escape($topic))
        }
        $script:runbook08 | Should -Not -Match ([regex]::Escape('**Fallback:** none needed'))
        $adr020 = Get-Content (Get-RepoPath 'docs/decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md') -Raw
        foreach ($topic in 'Dated exception: a hotfix SKU', 'Standard_RAGRS', 'time-box', 'Reverted') {
            $adr020 | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'the DR verification VM has no NIC NSG and no JIT policy, recorded in the runbook and ADR-028' {
        $start = $script:runbook08.IndexOf('8. **Verify**')
        $verify = $script:runbook08.Substring($start, $script:runbook08.IndexOf('## 5. Manual and post-deployment steps') - $start)
        $verify | Should -Match ([regex]::Escape('No NIC NSG and no JIT policy'))
        $adr028 = Get-Content (Get-RepoPath 'docs/decisions/ADR-028-jit-access-and-nsg-ownership.md') -Raw
        $adr028 | Should -Match ([regex]::Escape('The DR verification host (runbook 08 §4 step 8) has neither a NIC NSG nor a JIT policy'))
    }

    It 'the DR runbook uses the policy assignment name, not the definition name, for the public IP allowlist check' {
        $start = $script:runbook08.IndexOf('8. **Verify**')
        $verify = $script:runbook08.Substring($start, $script:runbook08.IndexOf('## 5. Manual and post-deployment steps') - $start)
        $verify | Should -Match ([regex]::Escape('`defenstack-deny-public-ip`'))
        $verify | Should -Not -Match ([regex]::Escape('`defenstack-deny-public-ip-except-allowlist`'))
    }
}
