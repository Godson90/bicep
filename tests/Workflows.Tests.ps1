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
