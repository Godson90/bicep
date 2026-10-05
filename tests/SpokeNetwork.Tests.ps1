BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/spokeNetwork.bicep'
    $routeTables = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables'
    $vnetModule = Get-TemplateResource -Template $template -Type 'Microsoft.Resources/deployments' | Select-Object -First 1
    # Subnet order in spokeNetwork.bicep: 0 private-endpoints, 1 appservice-integration, 2 management.
    $subnets = @($vnetModule.properties.parameters.subnets.value)
}

Describe 'Spoke routing (F2)' {
    It 'has one route table for App Service and one for the management subnet' {
        $routeTables.Count | Should -Be 2
    }

    It 'disables BGP route propagation on every spoke route table so gateway routes cannot bypass the firewall' {
        foreach ($routeTable in $routeTables) {
            $routeTable.properties.disableBgpRoutePropagation | Should -BeTrue
        }
    }
}

Describe 'Management subnet isolation (F1)' {
    It 'uses its own NSG, not the App Service integration NSG' {
        $subnets[2].nsgId | Should -Not -Be $subnets[1].nsgId
    }

    It 'uses its own route table, not the App Service route table' {
        $subnets[2].udrId | Should -Not -Be $subnets[1].udrId
    }

    It 'defaults to no management source CIDRs (deny all admin inbound)' {
        @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
    }

    It 'keeps the subnet allow for the admin sources only, so a JIT grant on the NIC NSG can pass it (ADR-028)' {
        $template.variables.managementInboundRules | Should -Match ([regex]::Escape("if(empty(parameters('managementSourceCidrs')), createArray(), createArray(createObject('name', 'allow-management-ssh-rdp'"))
        $template.variables.managementInboundRules | Should -Match ([regex]::Escape("'priority', 100, 'access', 'Allow'"))
        $template.variables.managementInboundRules | Should -Match ([regex]::Escape("'sourceAddressPrefixes', parameters('managementSourceCidrs')"))
        $template.variables.managementInboundRules | Should -Match ([regex]::Escape("'destinationAddressPrefix', parameters('virtualMachineSubnetAddressPrefix')"))
    }
}

Describe 'Subnet default outbound access (PSRule Azure.VNET.PrivateSubnet)' {
    It 'disables default outbound internet access on the private endpoint and management subnets' {
        $subnets[0].defaultOutboundAccess | Should -Be $false
        $subnets[2].defaultOutboundAccess | Should -Be $false
    }

    It 'leaves the delegated App Service integration subnet unset (delegation manages its own egress)' {
        $subnets[1].PSObject.Properties.Name | Should -Not -Contain 'defaultOutboundAccess'
    }
}

Describe 'Management subnet naming (Phase 1)' {
    It 'names the third subnet management' {
        $template.parameters.virtualMachineSubnetName.defaultValue | Should -Be 'management'
    }
}

Describe 'Lateral traversal (PSRule Azure.NSG.LateralTraversal, Phase 3)' {
    It 'denies outbound SSH and RDP from every spoke subnet' {
        $template.variables.denyLateralTraversalRule.properties.access | Should -Be 'Deny'
        $template.variables.denyLateralTraversalRule.properties.direction | Should -Be 'Outbound'
        @($template.variables.denyLateralTraversalRule.properties.destinationPortRanges) -join ',' | Should -Be '22,3389'
        $nsgs = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups'
        $nsgs.Count | Should -Be 3
        foreach ($nsg in $nsgs) {
            # Plain NSGs list the variable as an array element; the management NSG compiles to one concat() expression.
            (@($nsg.properties.securityRules) -join ' ').Contains("variables('denyLateralTraversalRule')") | Should -BeTrue
        }
    }
}

Describe 'Azure Monitor endpoint isolation (Phase 6 final review I-1)' {
    BeforeAll {
        $asgs = @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/applicationSecurityGroups')
        $privateEndpointNsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' |
            Where-Object { $_.name -eq "[variables('privateEndpointNsgName')]" }
    }

    It 'always creates one application security group for the AMPLS endpoint, named after the spoke VNet' {
        $asgs.Count | Should -Be 1
        $asgs[0].apiVersion | Should -Be '2024-07-01'
        $template.variables.amplsAsgName | Should -Be "[format('{0}-ampls-asg', parameters('vnetName'))]"
        $asgs[0].name | Should -Be "[variables('amplsAsgName')]"
        $asgs[0].location | Should -Be "[parameters('location')]"
        $asgs[0].PSObject.Properties.Name | Should -Not -Contain 'condition'
    }

    It 'outputs the application security group ID as amplsAsgId' {
        $template.outputs.amplsAsgId.value | Should -Be "[resourceId('Microsoft.Network/applicationSecurityGroups', variables('amplsAsgName'))]"
    }

    It 'takes the peer monitoring sources as a parameter, empty by default (no rule)' {
        @($template.parameters.monitorPeerSourceCidrs.defaultValue).Count | Should -Be 0
        $template.variables.peerMonitoringInboundRules | Should -Be "[if(empty(parameters('monitorPeerSourceCidrs')), createArray(), createArray(variables('peerMonitoringRule')))]"
    }

    It 'lets the peer sources reach only the AMPLS application security group, on TCP 443' {
        $rule = $template.variables.peerMonitoringRule
        $rule.name | Should -Be 'allow-peer-monitoring-https'
        $rule.properties.priority | Should -Be 110
        $rule.properties.direction | Should -Be 'Inbound'
        $rule.properties.access | Should -Be 'Allow'
        $rule.properties.protocol | Should -Be 'Tcp'
        $rule.properties.sourceAddressPrefixes | Should -Be "[parameters('monitorPeerSourceCidrs')]"
        $rule.properties.destinationPortRange | Should -Be '443'
        @($rule.properties.destinationApplicationSecurityGroups).Count | Should -Be 1
        $rule.properties.destinationApplicationSecurityGroups[0].id | Should -Be "[resourceId('Microsoft.Network/applicationSecurityGroups', variables('amplsAsgName'))]"
        $rule.properties.PSObject.Properties.Name | Should -Not -Contain 'destinationAddressPrefix'
    }

    It 'adds the peer rule to the private-endpoint NSG and keeps the approved-https rule on its own sources' {
        $rules = [string]$privateEndpointNsg.properties.securityRules
        $rules | Should -Match "variables\('peerMonitoringInboundRules'\)"
        $rules | Should -Match "'allow-approved-https'"
        $rules | Should -Match "'sourceAddressPrefixes', parameters\('approvedPrivateEndpointSourceCidrs'\)"
    }

    It 'enables NSG private endpoint network policies on the private-endpoint subnet, which application security groups on private endpoints need' {
        $subnets[0].privateEndpointNetworkPolicies | Should -Be 'NetworkSecurityGroupEnabled'
    }
}
