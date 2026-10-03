BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $scriptPath = Get-RepoPath 'scripts/New-GitHubDeploymentIdentity.ps1'
    $resourceGroups = @('rg-defenstack-dev-global', 'rg-defenstack-dev-wus3')

    # Shadows the Azure CLI for one test. $Responses maps a -like pattern (matched against the joined
    # arguments, first match wins) to the value to return; every call is recorded in $global:AzCalls.
    function Set-AzShadow([System.Collections.Specialized.OrderedDictionary]$Responses) {
        $global:AzCalls = [System.Collections.Generic.List[string]]::new()
        $global:FederatedCredentialPayloads = [System.Collections.Generic.List[string]]::new()
        $global:AzResponses = $Responses
        function global:az {
            $joined = $args -join ' '
            $global:AzCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'role definition create*') {
                $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                $global:RoleDefinitionPayload = Get-Content $file -Raw
            }
            if ($joined -like 'ad app federated-credential create*') {
                $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                $global:FederatedCredentialPayloads.Add((Get-Content $file -Raw))
            }
            foreach ($pattern in $global:AzResponses.Keys) {
                if ($joined -like $pattern) { return $global:AzResponses[$pattern] }
            }
            return ''
        }
    }

    function Remove-AzShadow {
        Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        Remove-Variable -Name AzResponses -Scope Global -ErrorAction SilentlyContinue
    }

    function New-BaseResponses {
        $responses = [ordered]@{}
        $responses['account show*tenantId*'] = '11111111-1111-1111-1111-111111111111'
        $responses['account show*'] = '22222222-2222-2222-2222-222222222222'
        $responses
    }
}

Describe 'New-GitHubDeploymentIdentity.ps1' {
    It 'exists and parses without errors' {
        $scriptPath | Should -Exist
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'supports -WhatIf' {
        (Get-Command $scriptPath).Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'makes no Azure or Entra changes under -WhatIf' {
        Set-AzShadow (New-BaseResponses)
        try {
            & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
        }
        finally {
            Remove-AzShadow
        }
        $mutations = $global:AzCalls | Where-Object { $_ -match '\b(create|delete|update|reset|add|remove)\b' }
        $mutations | Should -BeNullOrEmpty
    }

    It 'rejects delegating privileged role <_>' -ForEach @(
        '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
        '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
        'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
        'b24988ac-6180-42a0-ab88-20f7382dd24c'
    ) {
        Set-AzShadow (New-BaseResponses)
        try {
            { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds $_ -WhatIf } |
                Should -Throw -ExpectedMessage '*privileged*'
        }
        finally {
            Remove-AzShadow
        }
    }

    It 'rejects a delegatable role ID that is not a GUID' {
        Set-AzShadow (New-BaseResponses)
        try {
            { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds 'Owner' -WhatIf } |
                Should -Throw
        }
        finally {
            Remove-AzShadow
        }
    }

    It 'refuses to proceed when multiple applications share the display name' {
        $responses = New-BaseResponses
        $responses['*ad app list*'] = @('aaaaaaaa-1111-1111-1111-111111111111', 'bbbbbbbb-2222-2222-2222-222222222222')
        Set-AzShadow $responses
        try {
            { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                Should -Throw -ExpectedMessage '*Multiple Entra applications*'
        }
        finally {
            Remove-AzShadow
        }
    }

    It 'refuses an existing federated credential with a different subject' {
        $responses = New-BaseResponses
        $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
        $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
        $responses['*federated-credential list*'] = 'repo:someone-else/bicep:environment:dev'
        Set-AzShadow $responses
        try {
            { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
        }
        finally {
            Remove-AzShadow
        }
    }

    It 'refuses an existing unconditioned RBAC Administrator assignment' {
        $responses = New-BaseResponses
        $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
        $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
        $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
        $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
        $responses['*role definition list*'] = 'existing-custom-role'
        $responses['*role assignment list*condition*'] = ''
        $responses['*role assignment list*'] = 'eeeeeeee-5555-5555-5555-555555555555'
        Set-AzShadow $responses
        try {
            { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                Should -Throw -ExpectedMessage '*unconditioned*'
        }
        finally {
            Remove-AzShadow
        }
    }

    Context 'when creating assignments (non-WhatIf run against the shadow)' {
        BeforeAll {
            $responses = New-BaseResponses
            $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
            $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
            $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
            $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
            $responses['*role definition list*'] = 'existing-custom-role'
            Set-AzShadow $responses
            try {
                & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
            }
            finally {
                Remove-AzShadow
            }
            $creates = @($global:AzCalls | Where-Object { $_ -like 'role assignment create*' })
        }

        It 'assigns the subscription deployment role at subscription scope only' {
            $deploymentAssignments = @($creates | Where-Object { $_ -like "*--role DefenStack Subscription Deployment Operator*" })
            $deploymentAssignments.Count | Should -Be 1
            $deploymentAssignments[0] | Should -BeLike '*--scope /subscriptions/22222222-2222-2222-2222-222222222222 *'
        }

        It 'assigns Contributor and constrained RBAC Administrator on each resource group, never at subscription scope' {
            foreach ($resourceGroup in $resourceGroups) {
                $scope = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/$resourceGroup"
                @($creates | Where-Object { $_ -like "*--role Contributor --scope $scope *" }).Count | Should -Be 1
                @($creates | Where-Object { $_ -like "*--role Role Based Access Control Administrator --scope $scope *" }).Count | Should -Be 1
            }
            @($creates | Where-Object { $_ -like '*--role Contributor --scope /subscriptions/22222222-2222-2222-2222-222222222222 *' }).Count | Should -Be 0
        }

        It 'constrains RBAC Administrator with the exact ABAC condition for the delegatable roles (Storage Blob Data Contributor, Virtual Machine Administrator Login, Storage Blob Data Reader, Monitoring Metrics Publisher)' {
            $expected = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb}))"
            $rbacAdmin = @($creates | Where-Object { $_ -like '*--role Role Based Access Control Administrator*' })
            $rbacAdmin.Count | Should -Be 2
            foreach ($call in $rbacAdmin) {
                # Literal match: the condition contains [ and ], which -like would treat as wildcards.
                $call.Contains("--condition $expected --condition-version 2.0") | Should -BeTrue -Because $call
            }
        }
    }

    Context 'when creating the subscription deployment role (role definition missing)' {
        BeforeAll {
            $responses = New-BaseResponses
            $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
            $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
            $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
            $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
            $responses['*role definition list*'] = ''
            Set-AzShadow $responses
            try {
                & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
            }
            finally {
                Remove-AzShadow
            }
            $script:roleDefinitionPayload = $global:RoleDefinitionPayload | ConvertFrom-Json
        }

        It 'grants exactly the 9 deployment-operation and read-only actions, no wildcard' {
            $expectedActions = @(
                'Microsoft.Resources/deployments/read',
                'Microsoft.Resources/deployments/write',
                'Microsoft.Resources/deployments/validate/action',
                'Microsoft.Resources/deployments/whatIf/action',
                'Microsoft.Resources/deployments/operations/read',
                'Microsoft.Resources/deployments/operationstatuses/read',
                'Microsoft.Resources/subscriptions/read',
                'Microsoft.Resources/subscriptions/resourceGroups/read',
                'Microsoft.Resources/subscriptions/operationresults/read'
            )
            @($script:roleDefinitionPayload.Actions | Sort-Object) | Should -Be @($expectedActions | Sort-Object)
            $script:roleDefinitionPayload.Actions | Should -Not -Contain '*'
        }

        It 'is assignable only at the subscription scope' {
            @($script:roleDefinitionPayload.AssignableScopes) | Should -Be @('/subscriptions/22222222-2222-2222-2222-222222222222')
        }
    }

    Context 'federated credentials for the plan and apply environments (Phase 2)' {
        It 'creates github-<env> and github-<env>-plan with their exact environment subjects' {
            $responses = New-BaseResponses
            $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
            $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
            $responses['*role definition list*'] = 'existing-custom-role'
            Set-AzShadow $responses
            try {
                & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
            }
            finally {
                Remove-AzShadow
            }
            $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
            $credentials.Count | Should -Be 2
            ($credentials | Where-Object { $_.name -eq 'github-dev' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev'
            ($credentials | Where-Object { $_.name -eq 'github-dev-plan' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev-plan'
            foreach ($credential in $credentials) {
                $credential.issuer | Should -BeExactly 'https://token.actions.githubusercontent.com'
                @($credential.audiences) | Should -Be @('api://AzureADTokenExchange')
            }
        }

        It 'creates only github-staging for an environment not on the ungated-plan allowlist, with no plan credential (Final review D.7, fail closed)' {
            $responses = New-BaseResponses
            $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
            $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
            $responses['*role definition list*'] = 'existing-custom-role'
            Set-AzShadow $responses
            try {
                & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'staging' -Confirm:$false | Out-Null
            }
            finally {
                Remove-AzShadow
            }
            $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
            $credentials.Count | Should -Be 1
            $credentials[0].name | Should -BeExactly 'github-staging'
            $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:staging'
        }

        It 'creates only github-prod for the prod environment, with no plan credential' {
            $responses = New-BaseResponses
            $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
            $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
            $responses['*role definition list*'] = 'existing-custom-role'
            Set-AzShadow $responses
            try {
                & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'prod' -Confirm:$false | Out-Null
            }
            finally {
                Remove-AzShadow
            }
            $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
            $credentials.Count | Should -Be 1
            $credentials[0].name | Should -BeExactly 'github-prod'
            $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:prod'
        }

        It 'refuses an existing credential whose subject differs only in case' {
            $responses = New-BaseResponses
            $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
            $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
            $responses['*federated-credential list*'] = 'repo:godson90/bicep:environment:dev'
            Set-AzShadow $responses
            try {
                { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                    Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
            }
            finally {
                Remove-AzShadow
            }
        }
    }
}

Describe 'Role GUIDs are all delegatable' {
    It 'includes every role-definition GUID used in modules/*.bicep in the default -DelegatableRoleDefinitionIds list' {
        $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $roleGuids = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($file in Get-ChildItem (Get-RepoPath 'modules') -Filter '*.bicep') {
            $text = Get-Content $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, "subscriptionResourceId\('Microsoft\.Authorization/roleDefinitions',\s*'($guidPattern)'\)")) {
                [void]$roleGuids.Add($match.Groups[1].Value.ToLowerInvariant())
            }
            foreach ($match in [regex]::Matches($text, "(?:roleDefinitionId|roleId|\w*RoleId)\s*=\s*'($guidPattern)'")) {
                [void]$roleGuids.Add($match.Groups[1].Value.ToLowerInvariant())
            }
        }

        # The test must not pass vacuously: it has to find at least one GUID to check.
        $roleGuids.Count | Should -BeGreaterThan 0

        # Strip comments first, so a parenthesis inside one (e.g. "(app identity, container scope)")
        # cannot be mistaken for the end of the @(...) array below.
        $scriptTextNoComments = (Get-Content $scriptPath -Raw) -replace '#[^\r\n]*', ''
        $defaultBlock = [regex]::Match($scriptTextNoComments, '\$DelegatableRoleDefinitionIds\s*=\s*@\((.*?)\)', 'Singleline').Groups[1].Value
        $defaultBlock | Should -Not -BeNullOrEmpty

        foreach ($roleGuid in $roleGuids) {
            $defaultBlock | Should -Match ([regex]::Escape($roleGuid))
        }
    }
}

AfterAll {
    Remove-Variable -Name AzCalls, FederatedCredentialPayloads, RoleDefinitionPayload -Scope Global -ErrorAction SilentlyContinue
}
