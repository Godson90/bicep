BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/vpnGateway.bicep'
    $gateway = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworkGateways' | Select-Object -First 1
    $publicIps = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
    $maintenance = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/maintenanceConfigurations' | Select-Object -First 1
    $assignment = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/configurationAssignments' | Select-Object -First 1
    $client = $gateway.properties.vpnClientConfiguration
}

Describe 'Point-to-site VPN gateway (Phase 3)' {
    It 'accepts only zone-redundant (AZ) SKUs' {
        @($template.parameters.skuName.allowedValues) -join ',' | Should -Be 'VpnGw1AZ,VpnGw2AZ,VpnGw3AZ'
    }

    It 'runs a route-based Generation2 gateway, active-active with one zonal public IP per instance (PSRule Azure.VNG.VPNActiveActive)' {
        $gateway.properties.vpnType | Should -Be 'RouteBased'
        $gateway.properties.vpnGatewayGeneration | Should -Be 'Generation2'
        $gateway.properties.activeActive | Should -BeExactly $true
        @($template.variables.instances).Count | Should -Be 2
        $publicIps.copy.count | Should -Be "[length(variables('instances'))]"
        $publicIps.zones | Should -Be "[parameters('availabilityZones')]"
        ($gateway.properties.copy | Where-Object { $_.name -eq 'ipConfigurations' }).count | Should -Be "[length(variables('instances'))]"
    }

    It 'accepts only OpenVPN clients authenticated by Microsoft Entra ID' {
        @($client.vpnClientProtocols) -join ',' | Should -Be 'OpenVPN'
        @($client.vpnAuthenticationTypes) -join ',' | Should -Be 'AAD'
        $client.aadAudience | Should -Be "[parameters('vpnClientAudience')]"
        $template.parameters.vpnClientAudience.defaultValue | Should -Be 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
    }

    It 'builds the tenant and issuer URLs from the tenant ID and the cloud login endpoint' {
        $client.aadTenant | Should -Be "[format('{0}{1}/', environment().authentication.loginEndpoint, parameters('tenantId'))]"
        $client.aadIssuer | Should -Be "[format('https://sts.windows.net/{0}/', parameters('tenantId'))]"
        $template.parameters.tenantId.defaultValue | Should -Be '[tenant().tenantId]'
    }

    It 'assigns clients addresses from the region pool' {
        @($client.vpnClientAddressPool.addressPrefixes) | Should -Be @("[parameters('vpnClientAddressPool')]")
    }

    It 'patches the gateway only inside a weekly customer-controlled window of at least 5 hours (PSRule Azure.VNG.MaintenanceConfig)' {
        $maintenance.properties.maintenanceScope | Should -Be 'Resource'
        $maintenance.properties.maintenanceWindow.duration | Should -Be '05:00'
        $maintenance.properties.maintenanceWindow.recurEvery | Should -Be 'Week Sunday'
        $assignment.scope | Should -Match 'virtualNetworkGateways'
    }
}
