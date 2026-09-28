BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/monitoring.bicep'
}

Describe 'Log Analytics retention (F10)' {
    It 'retains 90 days by default (Sentinel free retention window)' {
        $template.parameters.retentionInDays.defaultValue | Should -Be 90
    }

    It 'bounds retention to supported values' {
        $template.parameters.retentionInDays.minValue | Should -Be 30
        $template.parameters.retentionInDays.maxValue | Should -Be 730
    }
}

Describe 'Log Analytics resilience (Phase 1)' {
    BeforeAll {
        $workspace = Get-TemplateResource -Template $template -Type 'Microsoft.OperationalInsights/workspaces' | Select-Object -First 1
        $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
    }

    It 'replicates the workspace only when a replication region is supplied' {
        $template.parameters.replicationLocation.defaultValue | Should -BeExactly ''
        $workspace.properties.replication | Should -Match "if\(empty\(parameters\('replicationLocation'\)\), null\(\)"
        $workspace.properties.replication | Should -Match "'location', parameters\('replicationLocation'\)"
    }

    It 'locks the workspace only when deletion protection is requested' {
        $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
        $lock.properties.level | Should -Be 'CanNotDelete'
    }
}
