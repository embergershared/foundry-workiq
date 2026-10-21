# Module-specific assertions for 'ai-foundry'.
#
# The uniform contract (params, outputs, metadata schema, catalog sync, build
# and lint) is already covered by tests/catalog.tests.ps1 and tests/bicep.tests.ps1.
# Add assertions here only for behaviour unique to this module.

. (Join-Path $PSScriptRoot '..' 'assert.ps1')
. (Join-Path $PSScriptRoot '..' 'common.ps1')

Test-Case 'ai-foundry declares the resource properties it needs' {
    $bicep = Get-Content -LiteralPath (Get-RepoPath 'infra/modules/ai-foundry/main.bicep') -Raw
    Assert-NotMatch -Actual $bicep -Pattern 'TODO' `
        -Message 'The scaffolded placeholders must be replaced before the module ships.'
    Assert-Match -Actual $bicep -Pattern 'disableLocalAuth:\s*true' `
        -Message 'The Foundry account must keep key authentication disabled.'
}

Test-Case 'ai-foundry grants Foundry User on both the account and the project' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/modules/ai-foundry/main.bicep')

    Assert-Match -Actual ([string] $template.variables.foundryUserRoleId) `
        -Pattern '53ca6127-db72-4b80-b1b0-d745d6d5456d' -Message 'foundryUserRoleId must be the Foundry User role.'
    Assert-Match -Actual ([string] $template.variables.foundryProjectManagerRoleId) `
        -Pattern 'eadc314b-1a2d-4efa-be10-5d325db5065e' -Message 'foundryProjectManagerRoleId must be the Foundry Project Manager role.'

    # Work IQ calls fail with "Principal does not have access to API/Operation"
    # when either scope is missing, so both are asserted by scope.
    $expected = @(
        @{ Name = 'accountUserAssignments'; Role = 'foundryUserRoleId'; Scope = "Microsoft.CognitiveServices/accounts'" }
        @{ Name = 'projectUserAssignments'; Role = 'foundryUserRoleId'; Scope = "Microsoft.CognitiveServices/accounts/projects'" }
        @{ Name = 'projectManagerAssignments'; Role = 'foundryProjectManagerRoleId'; Scope = "Microsoft.CognitiveServices/accounts/projects'" }
    )
    foreach ($assignment in $expected) {
        $resource = $template.resources.($assignment.Name)
        Assert-True -Condition ($null -ne $resource) -Message "ai-foundry must declare '$($assignment.Name)'."
        Assert-Match -Actual ([string] $resource.properties.roleDefinitionId) -Pattern $assignment.Role `
            -Message "'$($assignment.Name)' must assign '$($assignment.Role)'."
        Assert-Match -Actual ([string] $resource.scope) -Pattern ([regex]::Escape($assignment.Scope)) `
            -Message "'$($assignment.Name)' must be scoped to $($assignment.Scope.TrimEnd("'"))."
    }
}
