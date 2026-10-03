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
        $workspace.properties.replication.enabled | Should -Be "[not(empty(parameters('replicationLocation')))]"
        $workspace.properties.replication.location | Should -Be "[if(empty(parameters('replicationLocation')), null(), parameters('replicationLocation'))]"
    }

    It 'locks the workspace only when deletion protection is requested' {
        $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
        $lock.properties.level | Should -Be 'CanNotDelete'
    }
}

Describe 'Private-only workspace (Phase 6)' {
    BeforeAll {
        $workspace = Get-TemplateResource -Template $template -Type 'Microsoft.OperationalInsights/workspaces' | Select-Object -First 1
    }

    It 'accepts ingestion and queries only through the Azure Monitor Private Link Scope (F10)' {
        $workspace.properties.publicNetworkAccessForIngestion | Should -Be 'Disabled'
        $workspace.properties.publicNetworkAccessForQuery | Should -Be 'Disabled'
    }

    It 'keeps 90-day retention unchanged' {
        $workspace.properties.retentionInDays | Should -Be "[parameters('retentionInDays')]"
    }
}

Describe 'Microsoft Sentinel (Phase 6)' {
    BeforeAll {
        $onboarding = Get-TemplateResource -Template $template -Type 'Microsoft.SecurityInsights/onboardingStates' | Select-Object -First 1
    }

    It 'onboards the workspace to Sentinel in every environment' {
        $onboarding | Should -Not -BeNullOrEmpty
        $onboarding.PSObject.Properties.Name | Should -Not -Contain 'condition'
        $onboarding.name | Should -Be 'default'
    }

    It 'is an extension resource on the workspace, not the legacy SecurityInsights solution' {
        $onboarding.scope | Should -Be "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspaceName'))]"
        @(Get-TemplateResource -Template $template -Type 'Microsoft.OperationsManagement/solutions').Count | Should -Be 0
    }

    It 'pins the GA API version 2024-03-01' {
        $onboarding.apiVersion | Should -Be '2024-03-01'
    }

    It 'outputs the workspace name for runbook 06' {
        $template.outputs.PSObject.Properties.Name | Should -Contain 'name'
    }
}
