BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $paramFiles = Get-ChildItem -Path (Join-Path $repoRoot 'params') -Filter '*.bicepparam' -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
}

Describe 'Committed parameter files' {
    It 'includes a dev parameter file' {
        Get-RepoPath 'params/dev.bicepparam' | Should -Exist
    }

    It '<Name> builds against main.bicep' -ForEach $paramFiles {
        $output = & bicep build-params $FullName --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It '<Name> contains no az.getSecret references (secrets belong in *.local.bicepparam)' -ForEach $paramFiles {
        Get-Content $FullName -Raw | Should -Not -Match 'getSecret'
    }
}
