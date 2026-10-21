<#
.SYNOPSIS
    Compatibility shim for the naming tests.
.DESCRIPTION
    The naming checks moved into the tests/ suite when the conventions layer was
    extracted into infra/core. This wrapper stays so older docs, muscle memory
    and CI definitions keep working; it simply forwards to tests/run-tests.ps1.
.PARAMETER All
    Run the whole suite instead of only the naming cases.
.EXAMPLE
    ./scripts/test-naming.ps1
.EXAMPLE
    ./scripts/test-naming.ps1 -All
#>
[CmdletBinding()]
param(
    [switch] $All
)

$ErrorActionPreference = 'Stop'

$runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/run-tests.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "The test runner '$runner' is missing."
}

Write-Verbose "scripts/test-naming.ps1 now forwards to $runner."

if ($All) {
    & $runner
}
else {
    & $runner -Name 'naming'
}