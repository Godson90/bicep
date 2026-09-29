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
