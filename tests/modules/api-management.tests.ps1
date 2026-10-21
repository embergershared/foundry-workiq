# Module-specific assertions for 'api-management'.
#
# The uniform contract (params, outputs, metadata schema, catalog sync, build
# and lint) is already covered by tests/catalog.tests.ps1 and tests/bicep.tests.ps1.
# Add assertions here only for behaviour unique to this module.

. (Join-Path $PSScriptRoot '..' 'assert.ps1')
. (Join-Path $PSScriptRoot '..' 'common.ps1')

Test-Case 'api-management only offers tiers Foundry accepts as an AI Gateway' {
    $bicep = Get-Content -LiteralPath (Get-RepoPath 'infra/modules/api-management/main.bicep') -Raw
    Assert-NotMatch -Actual $bicep -Pattern 'TODO' `
        -Message 'The scaffolded placeholders must be replaced before the module ships.'

    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/modules/api-management/main.bicep')
    $tiers = @($template.parameters.sku.allowedValues)
    Assert-True -Condition ($tiers.Count -gt 0 -and @($tiers | Where-Object { $_ -notmatch 'V2$' }).Count -eq 0) `
        -Message 'Foundry lists only v2-tier instances under Use existing APIM, so every allowed tier must be a v2 tier.'
    Assert-Equal -Actual $template.parameters.sku.defaultValue -Expected 'BasicV2' `
        -Message 'Basic v2 must stay the default tier.'
    Assert-Equal -Actual ([string] $template.resources.apiManagement.identity.type) -Expected 'SystemAssigned' `
        -Message 'The gateway calls the Foundry models with its managed identity.'
}

Test-Case 'api-management grants each gateway role at the scope that needs it' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/modules/api-management/main.bicep')

    $roles = @{
        cognitiveServicesUserRoleId           = 'a97b65f3-24c7-4388-baec-2e87135dc908'
        apiManagementServiceContributorRoleId = '312a565d-c81f-4fd8-895a-4e21e48d571c'
        foundryAccountOwnerRoleId             = 'e47c6f54-e4a2-4754-9501-8e0985b135e1'
    }
    foreach ($role in $roles.GetEnumerator()) {
        Assert-Match -Actual ([string] $template.variables.($role.Key)) -Pattern $role.Value `
            -Message "$($role.Key) must be role $($role.Value)."
    }

    # The gateway identity calls the models; the admin links the gateway in the
    # Foundry portal, which needs both the instance and the account roles.
    $expected = @(
        @{ Name = 'gatewayInferenceAssignment'; Role = 'cognitiveServicesUserRoleId'; Scope = "Microsoft.CognitiveServices/accounts'" }
        @{ Name = 'serviceContributorAssignments'; Role = 'apiManagementServiceContributorRoleId'; Scope = "Microsoft.ApiManagement/service'" }
        @{ Name = 'foundryAccountOwnerAssignments'; Role = 'foundryAccountOwnerRoleId'; Scope = "Microsoft.CognitiveServices/accounts'" }
    )
    foreach ($assignment in $expected) {
        $resource = $template.resources.($assignment.Name)
        Assert-True -Condition ($null -ne $resource) -Message "api-management must declare '$($assignment.Name)'."
        Assert-Match -Actual ([string] $resource.properties.roleDefinitionId) -Pattern $assignment.Role `
            -Message "'$($assignment.Name)' must assign '$($assignment.Role)'."
        Assert-Match -Actual ([string] $resource.scope) -Pattern ([regex]::Escape($assignment.Scope)) `
            -Message "'$($assignment.Name)' must be scoped to $($assignment.Scope.TrimEnd("'"))."
    }
}
