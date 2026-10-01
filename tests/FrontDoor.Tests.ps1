BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/frontDoor.bicep'
    function Get-One([string]$Type) { Get-TemplateResource -Template $template -Type $Type | Select-Object -First 1 }
    $frontDoorProfile = Get-One 'Microsoft.Cdn/profiles'
    $waf = Get-One 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies'
    $originGroup = Get-One 'Microsoft.Cdn/profiles/originGroups'
    $origins = Get-One 'Microsoft.Cdn/profiles/originGroups/origins'
    $route = Get-One 'Microsoft.Cdn/profiles/afdEndpoints/routes'
    $customDomain = Get-One 'Microsoft.Cdn/profiles/customDomains'
    $securityPolicy = Get-One 'Microsoft.Cdn/profiles/securityPolicies'
    $diagnostics = Get-One 'Microsoft.Insights/diagnosticSettings'
    $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks'
}

Describe 'Front Door profile (Phase 4)' {
    It 'is a global Premium profile (Private Link origins and managed WAF rule sets need Premium)' {
        $frontDoorProfile.sku.name | Should -Be 'Premium_AzureFrontDoor'
        $frontDoorProfile.location | Should -Be 'global'
    }

    It 'has a system-assigned identity (PSRule Azure.FrontDoor.ManagedIdentity)' {
        $frontDoorProfile.identity.type | Should -Be 'SystemAssigned'
    }

    It 'sends access, health probe and WAF logs to the central workspace' {
        $diagnostics.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
        $diagnostics.properties.logs[0].categoryGroup | Should -Be 'allLogs'
    }

    It 'locks the profile and the WAF policy only when requested' {
        $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
        $locks.Count | Should -Be 2
        foreach ($lock in $locks) {
            $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
            $lock.properties.level | Should -Be 'CanNotDelete'
        }
    }
}

Describe 'WAF policy (Phase 4)' {
    It 'blocks in Prevention mode in every environment and inspects request bodies' {
        $waf.sku.name | Should -Be 'Premium_AzureFrontDoor'
        $waf.properties.policySettings.enabledState | Should -Be 'Enabled'
        $waf.properties.policySettings.mode | Should -Be 'Prevention'
        $waf.properties.policySettings.requestBodyCheck | Should -Be 'Enabled'
    }

    It 'runs Microsoft Default Rule Set 2.1 (blocking) and Bot Manager 1.1' {
        $sets = @($waf.properties.managedRules.managedRuleSets)
        $drs = $sets | Where-Object { $_.ruleSetType -eq 'Microsoft_DefaultRuleSet' }
        $drs.ruleSetVersion | Should -Be '2.1'
        $drs.ruleSetAction | Should -Be 'Block'
        ($sets | Where-Object { $_.ruleSetType -eq 'Microsoft_BotManagerRuleSet' }).ruleSetVersion | Should -Be '1.1'
    }

    It 'rate-limits each client IP per minute, 1000 requests by default' {
        $rule = $template.variables.rateLimitRule
        $rule.ruleType | Should -Be 'RateLimitRule'
        $rule.rateLimitDurationInMinutes | Should -Be 1
        $rule.rateLimitThreshold | Should -Be "[parameters('rateLimitThresholdPerMinute')]"
        $rule.action | Should -Be 'Block'
        @($rule.matchConditions[0].matchValue) -join ',' | Should -Be '0.0.0.0/0,::/0'
        $template.parameters.rateLimitThresholdPerMinute.defaultValue | Should -Be 1000
        $waf.properties.customRules.rules | Should -Be "[concat(createArray(variables('rateLimitRule')), variables('geoFilterRules'))]"
    }

    It 'adds a geo-filter only when allowed countries are given (no filtering by default)' {
        @($template.parameters.allowedCountryCodes.defaultValue).Count | Should -Be 0
        $template.variables.geoFilterRules | Should -Match "^\[if\(empty\(parameters\('allowedCountryCodes'\)\), createArray\(\)"
        $template.variables.geoFilterRules | Should -Match "'GeoMatch', 'negateCondition', true\(\)"
    }

    It 'applies the WAF to the endpoint and, when set, the custom domain' {
        $securityPolicy.properties.parameters.type | Should -Be 'WebApplicationFirewall'
        $association = $securityPolicy.properties.parameters.associations[0]
        $association.domains | Should -Match "resourceId\('Microsoft.Cdn/profiles/afdEndpoints'"
        $association.domains | Should -Match "if\(variables\('hasCustomDomain'\)"
        @($association.patternsToMatch) -join ',' | Should -Be '/*'
    }
}

Describe 'Origins over Private Link (Phase 4)' {
    It 'creates one origin per entry, at most 5, in failover priority order' {
        $origins.copy.count | Should -Be "[length(parameters('origins'))]"
        $template.parameters.origins.maxLength | Should -Be 5
        $origins.properties.priority | Should -Be '[add(copyIndex(), 1)]'
    }

    It 'reaches each App Service through a sites private link with the approval request message' {
        $link = $origins.properties.sharedPrivateLinkResource
        $link.groupId | Should -Be 'sites'
        $link.privateLink.id | Should -Match 'appServiceId'
        $link.requestMessage | Should -Be "[variables('privateLinkRequestMessage')]"
        $template.variables.privateLinkRequestMessage | Should -Be 'defenstack-frontdoor'
        $template.outputs.privateLinkRequestMessage.value | Should -Be "[variables('privateLinkRequestMessage')]"
    }

    It 'checks the origin certificate name and sends the app hostname as the host header' {
        $origins.properties.enforceCertificateNameCheck | Should -BeExactly $true
        $origins.properties.originHostHeader | Should -Match 'hostName'
    }

    It 'probes the App Service health check path over HTTPS' {
        $originGroup.properties.healthProbeSettings.probePath | Should -Be "[parameters('healthProbePath')]"
        $originGroup.properties.healthProbeSettings.probeProtocol | Should -Be 'Https'
        $originGroup.properties.sessionAffinityState | Should -Be 'Disabled'
    }
}

Describe 'Route and custom domain (Phase 4)' {
    It 'redirects HTTP to HTTPS and forwards to origins over HTTPS only' {
        $route.properties.httpsRedirect | Should -Be 'Enabled'
        $route.properties.forwardingProtocol | Should -Be 'HttpsOnly'
        @($route.properties.patternsToMatch) -join ',' | Should -Be '/*'
        $route.properties.linkToDefaultDomain | Should -Be 'Enabled'
    }

    It 'waits for the origins (a route needs at least one origin in its group)' {
        @($route.dependsOn) | Should -Contain 'appOrigins'
    }

    It 'creates the custom domain only when a hostname is given, with a managed TLS 1.2 certificate' {
        $template.parameters.customDomainHostName.defaultValue | Should -Be ''
        $customDomain.condition | Should -Be "[variables('hasCustomDomain')]"
        $customDomain.properties.tlsSettings.certificateType | Should -Be 'ManagedCertificate'
        $customDomain.properties.tlsSettings.minimumTlsVersion | Should -Be 'TLS12'
        $route.properties.customDomains | Should -Match "^\[if\(variables\('hasCustomDomain'\)"
    }

    It 'outputs the endpoint hostname and the TXT validation token for the external DNS host' {
        $template.outputs.endpointHostName.value | Should -Match 'hostName'
        $template.outputs.customDomainValidationToken.value | Should -Match 'validationToken'
    }
}
