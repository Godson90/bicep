BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/appService.bicep'
    $plan = Get-TemplateResource -Template $template -Type 'Microsoft.Web/serverfarms' | Select-Object -First 1
    $site = Get-TemplateResource -Template $template -Type 'Microsoft.Web/sites' | Select-Object -First 1
    $basicAuth = Get-TemplateResource -Template $template -Type 'Microsoft.Web/sites/basicPublishingCredentialsPolicies'
}

Describe 'App Service publishing credentials (F8)' {
    It 'disables basic authentication for FTP and SCM' {
        $basicAuth.Count | Should -Be 2
        foreach ($policy in $basicAuth) {
            $policy.properties.allow | Should -BeExactly $false
        }
    }
}

Describe 'App Service site configuration (F8)' {
    It 'keeps the instance warm and health-probed' {
        $site.properties.siteConfig.alwaysOn | Should -BeTrue
        $site.properties.siteConfig.healthCheckPath | Should -Be "[parameters('healthCheckPath')]"
    }

    It 'requires TLS 1.2 on the SCM endpoint and disables remote debugging' {
        $site.properties.siteConfig.scmMinTlsVersion | Should -Be '1.2'
        $site.properties.siteConfig.remoteDebuggingEnabled | Should -BeExactly $false
    }
}

Describe 'App Service client affinity (PSRule Azure.AppService.ARRAffinity)' {
    It 'disables ARR client affinity for the stateless site' {
        $site.properties.clientAffinityEnabled | Should -Be $false
    }
}

Describe 'App Service plan resilience parameters (F8)' {
    It 'exposes zone redundancy and instance count, defaulting to in-place-safe values' {
        $template.parameters.zoneRedundant.defaultValue | Should -BeExactly $false
        $template.parameters.instanceCount.defaultValue | Should -Be 1
        $plan.properties.zoneRedundant | Should -Be "[parameters('zoneRedundant')]"
        $plan.sku.capacity | Should -Be "[parameters('instanceCount')]"
    }
}
