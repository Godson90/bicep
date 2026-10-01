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
        $approve = $deploy.IndexOf('./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $ids')
        $approve | Should -BeGreaterThan $create
        $deploy | Should -Match ([regex]::Escape('--query properties.outputs.appServiceIds.value'))
        $deploy | Should -Match ([regex]::Escape('az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}"'))
    }

    It 'fails the job when the outputs cannot be read' {
        $deploy | Should -Match ([regex]::Escape("throw 'Could not read appServiceIds from the deployment outputs.'"))
    }
}
