BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/hubNetwork.bicep'
    $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
    $vnet = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworks' | Select-Object -First 1
    $routeTables = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables'
    $routeTable = $routeTables | Where-Object { $_.name -eq "[variables('gatewayRouteTableName')]" }
    $firewallRouteTable = $routeTables | Where-Object { $_.name -eq "[variables('firewallRouteTableName')]" }
    $bastionNsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' | Select-Object -First 1
    # Subnet names compile to variable references, for example [variables('gatewaySubnetName')].
    function Get-Subnet([string]$Name) {
        $variable = ($template.variables.PSObject.Properties | Where-Object { $_.Name -like '*SubnetName' -and $_.Value -ceq $Name }).Name
        $vnet.properties.subnets | Where-Object { $_.name -eq "[variables('$variable')]" }
    }
    function Get-NsgRule([string]$Name) { $bastionNsg.properties.securityRules | Where-Object { $_.name -eq $Name } }
}

Describe 'Hub network deletion protection (Phase 2)' {
    It 'locks the hub VNet only when requested' {
        $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
        $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
        $lock.properties.level | Should -Be 'CanNotDelete'
        $lock.scope | Should -Be "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]"
    }
}

Describe 'Hub subnets (Phase 3)' {
    It 'always creates the exact-case AzureFirewallSubnet, AzureBastionSubnet and GatewaySubnet' {
        $template.variables.firewallSubnetName | Should -BeExactly 'AzureFirewallSubnet'
        $template.variables.bastionSubnetName | Should -BeExactly 'AzureBastionSubnet'
        $template.variables.gatewaySubnetName | Should -BeExactly 'GatewaySubnet'
        @($vnet.properties.subnets.name) -join ',' | Should -Be "[variables('firewallSubnetName')],[variables('bastionSubnetName')],[variables('gatewaySubnetName')]"
        $vnet.PSObject.Properties.Name | Should -Not -Contain 'condition'
    }

    It 'outputs the Bastion and gateway subnet IDs' {
        foreach ($output in 'bastionSubnetId', 'gatewaySubnetId') {
            $template.outputs.PSObject.Properties.Name | Should -Contain $output
        }
    }
}

Describe 'Hub DNS (ADR-005, Phase 3)' {
    It 'points the hub, and so every VPN client, at the firewall DNS proxy' {
        @($vnet.properties.dhcpOptions.dnsServers) | Should -Be @("[parameters('firewallPrivateIp')]")
    }
}

Describe 'GatewaySubnet routing (F2, Phase 3)' {
    It 'attaches the gateway route table to GatewaySubnet only' {
        (Get-Subnet 'GatewaySubnet').properties.routeTable.id | Should -Match 'gatewayRouteTableName'
        (Get-Subnet 'AzureFirewallSubnet').properties.routeTable | Should -Not -Match 'gatewayRouteTableName'
        (Get-Subnet 'AzureBastionSubnet').properties.PSObject.Properties.Name | Should -Not -Contain 'routeTable'
    }

    It 'sends every spoke prefix from VPN clients to the firewall' {
        $routes = $routeTable.properties.copy | Where-Object { $_.name -eq 'routes' }
        $routes.count | Should -Be "[length(parameters('spokeAddressPrefixes'))]"
        $routes.input.properties.nextHopType | Should -Be 'VirtualAppliance'
        $routes.input.properties.nextHopIpAddress | Should -Be "[parameters('firewallPrivateIp')]"
    }

    It 'keeps BGP route propagation on (GatewaySubnet requires it)' {
        $routeTable.properties.disableBgpRoutePropagation | Should -BeExactly $false
    }
}

Describe 'Bastion NSG (Phase 3)' {
    It 'is attached to AzureBastionSubnet' {
        (Get-Subnet 'AzureBastionSubnet').properties.networkSecurityGroup.id | Should -Match 'bastionNsgName'
    }

    It 'allows the inbound rule Bastion requires: <Rule>' -ForEach @(
        @{ Rule = 'allow-https-inbound'; Source = 'Internet' }
        @{ Rule = 'allow-gateway-manager-inbound'; Source = 'GatewayManager' }
        @{ Rule = 'allow-load-balancer-inbound'; Source = 'AzureLoadBalancer' }
    ) {
        $rule = Get-NsgRule $Rule
        $rule.properties.access | Should -Be 'Allow'
        $rule.properties.direction | Should -Be 'Inbound'
        $rule.properties.sourceAddressPrefix | Should -Be $Source
        $rule.properties.destinationPortRange | Should -Be '443'
    }

    It 'allows Bastion data-plane traffic on 8080 and 5701 in both directions' {
        foreach ($name in 'allow-bastion-host-communication-inbound', 'allow-bastion-host-communication-outbound') {
            @((Get-NsgRule $name).properties.destinationPortRanges) -join ',' | Should -Be '8080,5701'
        }
    }

    It 'allows the AzureCloud and session-information egress Bastion requires' {
        (Get-NsgRule 'allow-azure-cloud-outbound').properties.destinationAddressPrefix | Should -Be 'AzureCloud'
        (Get-NsgRule 'allow-session-information-outbound').properties.destinationPortRange | Should -Be '80'
    }

    It 'opens SSH/RDP only to the management subnets, then denies all other SSH/RDP egress' {
        $allow = Get-NsgRule 'allow-ssh-rdp-to-management-outbound'
        $allow.properties.destinationAddressPrefixes | Should -Be "[parameters('bastionTargetAddressPrefixes')]"
        @($allow.properties.destinationPortRanges) -join ',' | Should -Be '22,3389'
        $deny = Get-NsgRule 'deny-other-ssh-rdp-outbound'
        $deny.properties.access | Should -Be 'Deny'
        $deny.properties.direction | Should -Be 'Outbound'
        $deny.properties.priority | Should -BeGreaterThan $allow.properties.priority
    }

    It 'denies all other inbound traffic' {
        (Get-NsgRule 'deny-unsolicited-inbound').properties.priority | Should -Be 4096
    }
}

Describe 'AzureFirewallSubnet routing for hub peering (Phase 6)' {
    It 'creates the firewall route table only when the other region''s spoke prefixes are given (prod with DR)' {
        $template.parameters.remoteSpokeAddressPrefixes.defaultValue.Count | Should -Be 0
        $template.parameters.remoteFirewallPrivateIp.defaultValue | Should -BeExactly ''
        $firewallRouteTable.condition | Should -Be "[not(empty(parameters('remoteSpokeAddressPrefixes')))]"
    }

    It 'attaches it to AzureFirewallSubnet only when it exists' {
        (Get-Subnet 'AzureFirewallSubnet').properties.routeTable |
            Should -Be "[if(empty(parameters('remoteSpokeAddressPrefixes')), null(), createObject('id', resourceId('Microsoft.Network/routeTables', variables('firewallRouteTableName'))))]"
    }

    It 'sends each remote spoke prefix to the remote firewall private IP' {
        $firewallRouteTable.properties.routes | Should -Be "[variables('firewallRoutes')]"
        $template.variables.firewallRoutes | Should -Match "map\(parameters\('remoteSpokeAddressPrefixes'\)"
        $template.variables.firewallRoutes | Should -Match "'nextHopType', 'VirtualAppliance', 'nextHopIpAddress', parameters\('remoteFirewallPrivateIp'\)"
    }

    It 'keeps 0.0.0.0/0 to Internet on the firewall subnet, as Azure Firewall requires once a route table is attached' {
        $template.variables.firewallRoutes | Should -Match "createObject\('name', 'default-to-internet', 'properties', createObject\('addressPrefix', '0.0.0.0/0', 'nextHopType', 'Internet'\)\)"
    }

    It 'keeps gateway route propagation on, so the firewall still returns traffic to VPN clients' {
        $firewallRouteTable.properties.disableBgpRoutePropagation | Should -BeExactly $false
    }
}
