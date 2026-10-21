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
}
