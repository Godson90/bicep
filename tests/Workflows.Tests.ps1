BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $ci = Get-Content (Get-RepoPath '.github/workflows/bicep-ci.yml') -Raw
    $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
}

Describe 'Workflows target the subscription scope' {
    It '<Name> uses az deployment sub, never az deployment group' -ForEach @(
        @{ Name = 'bicep-ci.yml'; Key = 'ci' },
        @{ Name = 'deploy.yml'; Key = 'deploy' }
    ) {
        $text = if ($Key -eq 'ci') { $ci } else { $deploy }
        $text | Should -Match 'az deployment sub '
        $text | Should -Not -Match 'az deployment group '
        $text | Should -Match 'DEPLOYMENT_LOCATION: westus3'
    }

    It '<Name> no longer reads the removed AZURE_RESOURCE_GROUP variable' -ForEach @(
        @{ Name = 'bicep-ci.yml'; Key = 'ci' },
        @{ Name = 'deploy.yml'; Key = 'deploy' }
    ) {
        $text = if ($Key -eq 'ci') { $ci } else { $deploy }
        $text | Should -Not -Match 'AZURE_RESOURCE_GROUP'
    }
}

Describe 'Deploy workflow gating' {
    It 'offers dev and prod and deploys only from main' {
        $deploy | Should -Match 'options: \[dev, prod\]'
        $deploy | Should -Match "if: github\.ref == 'refs/heads/main'"
        $deploy | Should -Match "environment: \$\{\{ inputs\.environment \|\| 'dev' \}\}"
    }

    It 'runs validate and what-if before create' {
        $validate = $deploy.IndexOf('az deployment sub validate')
        $whatIf = $deploy.IndexOf('az deployment sub what-if')
        $create = $deploy.IndexOf('az deployment sub create')
        $validate | Should -BeGreaterThan -1
        $whatIf | Should -BeGreaterThan $validate
        $create | Should -BeGreaterThan $whatIf
    }
}

Describe 'Deploy workflow plan/apply split (Phase 2)' {
    BeforeAll {
        $planStart = $deploy.IndexOf('  plan:')
        $applyStart = $deploy.IndexOf('  apply:')
        $planJob = $deploy.Substring($planStart, $applyStart - $planStart)
        $applyJob = $deploy.Substring($applyStart)
    }

    It 'has a plan job before an apply job' {
        $planStart | Should -BeGreaterThan -1
        $applyStart | Should -BeGreaterThan $planStart
    }

    It 'runs validate and what-if in the plan job, gated to prod for prod and dev-plan otherwise' {
        $planJob | Should -Match "environment: \$\{\{ inputs\.environment == 'prod' && 'prod' \|\| 'dev-plan' \}\}"
        $planJob | Should -Match 'az deployment sub validate'
        $planJob | Should -Match 'az deployment sub what-if'
        $planJob | Should -Not -Match 'az deployment sub create'
    }

    It 'creates only in the apply job, which waits for plan and runs in the reviewer-gated {env} environment' {
        $applyJob | Should -Match 'needs: plan'
        $applyJob | Should -Match "environment: \$\{\{ inputs\.environment \|\| 'dev' \}\}\s"
        $applyJob | Should -Match 'az deployment sub create'
        $applyJob | Should -Not -Match 'az deployment sub what-if'
    }

    It 'runs both jobs from main only' {
        ([regex]::Matches($deploy, "if: github\.ref == 'refs/heads/main'")).Count | Should -Be 2
    }

    It 'runs the PR what-if in dev-plan' {
        $ci | Should -Match 'environment: dev-plan'
    }

    It 'has no prod-plan environment anywhere' {
        $deploy | Should -Not -Match 'prod-plan'
    }

    It 'retains the what-if artifact for 14 days' {
        $planJob | Should -Match 'retention-days: 14'
    }

    It 'overwrites the what-if artifact so a re-run of a failed plan job does not fail on an existing artifact name (Final review D.4)' {
        $planJob | Should -Match 'overwrite: true'
    }
}

Describe 'Front Door private endpoint approval (Phase 4)' {
    It 'approves Front Door connections after the deployment, from the deployment outputs' {
        $create = $deploy.IndexOf('az deployment sub create')
        $approve = $deploy.IndexOf('./scripts/Approve-FrontDoorPrivateEndpoints.ps1')
        $approve | Should -BeGreaterThan $create
        $deploy | Should -Match ([regex]::Escape('--query properties.outputs --output json'))
        $deploy | Should -Match ([regex]::Escape('az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}"'))
    }

    It 'fails the job when the outputs cannot be read' {
        $deploy | Should -Match ([regex]::Escape("throw 'Could not read appServiceIds from the deployment outputs.'"))
        $deploy | Should -Match ([regex]::Escape("throw 'Could not read frontDoorProfileName from the deployment outputs.'"))
        $deploy | Should -Match ([regex]::Escape("throw 'Could not read globalResourceGroupName from the deployment outputs.'"))
    }

    It 'passes the Front Door profile and global resource group names to the approval script (final review A)' {
        $deploy | Should -Match ([regex]::Escape('-AppServiceId $ids -FrontDoorProfileName $profileName -FrontDoorResourceGroupName $resourceGroupName'))
    }

    It 'refreshes the Azure login right before the approval step, since the wait can outlast the first token' {
        $create = $deploy.IndexOf('az deployment sub create')
        $refresh = $deploy.IndexOf('Refresh Azure login before approval')
        $approve = $deploy.IndexOf('Approve Front Door private endpoint connections')
        $refresh | Should -BeGreaterThan $create
        $approve | Should -BeGreaterThan $refresh

        $applyStart = $deploy.IndexOf('  apply:')
        $applyJob = $deploy.Substring($applyStart)
        ([regex]::Matches($applyJob, 'uses: azure/login@v2')).Count | Should -Be 2
    }
}

Describe 'Alert email from the ALERT_EMAIL environment variable (Phase 6)' {
    BeforeAll {
        $applyStart = $deploy.IndexOf('  apply:')
        $applyJob = $deploy.Substring($applyStart)
        $planJob = $deploy.Substring(0, $applyStart)
        $alertEmailArgument = '--parameters alertEmail="$ALERT_EMAIL"'
        $alertEmailVariable = 'ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}'
    }

    It 'passes alertEmail from vars.ALERT_EMAIL to validate, what-if and create' {
        ([regex]::Matches($planJob, [regex]::Escape($alertEmailArgument))).Count | Should -Be 2
        ([regex]::Matches($applyJob, [regex]::Escape($alertEmailArgument))).Count | Should -Be 1
        ([regex]::Matches($deploy, [regex]::Escape($alertEmailVariable))).Count | Should -Be 5
    }

    It 'fails the prod plan first, before checkout and sign-in, when ALERT_EMAIL is empty (final review M-7)' {
        $planSteps = $planJob.Substring($planJob.IndexOf('  plan:'))
        $check = $planSteps.IndexOf('- name: Require ALERT_EMAIL for prod')
        $check | Should -BeGreaterThan -1
        $check | Should -BeLessThan $planSteps.IndexOf('- uses: actions/checkout@v4')
        $check | Should -BeLessThan $planSteps.IndexOf('uses: azure/login@v2')
        $planSteps.Substring($planSteps.IndexOf('steps:')).TrimStart() | Should -Match '^steps:\s+(#[^\n]*\n\s+)*- name: Require ALERT_EMAIL for prod'
        $step = $planSteps.Substring($check, $planSteps.IndexOf('- uses: actions/checkout@v4') - $check)
        $step | Should -Match "if: env\.TARGET_ENV == 'prod'"
        $step | Should -Match ([regex]::Escape($alertEmailVariable))
        $step | Should -Match ([regex]::Escape('if [ -z "$ALERT_EMAIL" ]; then'))
        $step | Should -Match 'exit 1'
        # The address reaches the script through env:, never interpolated into run:.
        $step.Substring($step.IndexOf('run:')) | Should -Not -Match '\$\{\{'
    }

    It 'passes alertEmail to the pull request what-if, so it shows no spurious receiver change' {
        $ci | Should -Match ([regex]::Escape($alertEmailArgument))
        $ci | Should -Match ([regex]::Escape($alertEmailVariable))
    }

    It 'fails the prod apply before signing in to Azure when ALERT_EMAIL is empty' {
        $check = $applyJob.IndexOf('- name: Require ALERT_EMAIL for prod')
        $check | Should -BeGreaterThan -1
        $check | Should -BeLessThan $applyJob.IndexOf('uses: azure/login@v2')
        $check | Should -BeLessThan $applyJob.IndexOf('az deployment sub create')
        $step = $applyJob.Substring($check, $applyJob.IndexOf('- uses: actions/checkout@v4') - $check)
        $step | Should -Match "if: env\.TARGET_ENV == 'prod'"
        $step | Should -Match ([regex]::Escape('if [ -z "$ALERT_EMAIL" ]; then'))
        $step | Should -Match 'exit 1'
    }
}

Describe 'Governance stays outside the pipeline (Phase 7)' {
    It 'does not redeploy the workload when only governance files change (a redeploy resets the JIT NSG rules, ADR-028)' {
        $deploy | Should -Match ([regex]::Escape("      - 'modules/**'"))
        $deploy | Should -Match ([regex]::Escape("      - '!modules/governance/**'"))
        $deploy | Should -Match ([regex]::Escape("      - '!params/governance.bicepparam'"))
        # GitHub applies path filters in order, so each exclusion must follow the pattern it narrows.
        $deploy.IndexOf("'!modules/governance/**'") | Should -BeGreaterThan $deploy.IndexOf("'modules/**'")
        $deploy.IndexOf("'!params/governance.bicepparam'") | Should -BeGreaterThan $deploy.IndexOf("'params/**'")
    }

    It 'deploys only the environment parameter files, never governance' {
        $deploy | Should -Match ([regex]::Escape('--parameters "params/${TARGET_ENV}.bicepparam"'))
        $deploy | Should -Match 'options: \[dev, prod\]'
    }

    It 'still runs PSRule over every parameter file, governance included, with a placeholder contact list' {
        $ci | Should -Match ([regex]::Escape('Assert-PSRule -InputPath params/'))
        $psRuleStep = $ci.Substring($ci.IndexOf('- name: PSRule for Azure'))
        $psRuleStep | Should -Match 'SECURITY_CONTACT_EMAILS: security-contact@example\.com'
    }
}
