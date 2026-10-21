<#
.SYNOPSIS
    Replaces the template owner's tenants and subscriptions with the example
    values in a repository created from the template.

.DESCRIPTION
    The template repository commits its owner's deployment specifics in a few
    files. Each one has an `.example` sibling holding neutral placeholder values:

      infra/core/tenant-codes.json   <- infra/core/tenant-codes.example.json
      docs/targets.md                <- docs/targets.example.md

    This script copies every example over its specifics file. The
    template-init workflow runs it on a new repository's first push; run it by
    hand when that workflow did not run. Running it again resets those files to
    the examples, so do not run it once the repository holds its own tenants.

.EXAMPLE
    ./scripts/init-from-template.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

$specifics = [ordered] @{
    'infra/core/tenant-codes.json' = 'infra/core/tenant-codes.example.json'
    'docs/targets.md'              = 'docs/targets.example.md'
}

foreach ($entry in $specifics.GetEnumerator()) {
    $target = Join-Path $repoRoot $entry.Key
    $example = Join-Path $repoRoot $entry.Value
    if (-not (Test-Path -LiteralPath $example)) {
        throw "Example file '$($entry.Value)' is missing; nothing was changed for '$($entry.Key)'."
    }
    if ((Test-Path -LiteralPath $target) -and
        (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $example).Hash) {
        Write-Output "Unchanged: $($entry.Key) already matches $($entry.Value)."
        continue
    }
    if ($PSCmdlet.ShouldProcess($entry.Key, "Replace with $($entry.Value)")) {
        Copy-Item -LiteralPath $example -Destination $target -Force
        Write-Output "Replaced: $($entry.Key) from $($entry.Value)."
    }
}
