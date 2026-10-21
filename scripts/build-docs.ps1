<#
.SYNOPSIS
    Regenerates the derived sections of docs/modules.md from module metadata.

.DESCRIPTION
    The module table and the private DNS zone table in docs/modules.md are
    projections of infra/modules/*/metadata.json. Hand-maintaining them means
    they drift the first time a module is added, so they are generated between
    marker comments instead. Prose outside the markers is edited by hand and is
    never touched by this script.

    Run with -Check to fail when the generated sections are stale, which is what
    the test suite and CI do.

.PARAMETER Check
    Compare the generated sections against what is on disk and throw when they
    differ, instead of writing.

.EXAMPLE
    ./scripts/build-docs.ps1

.EXAMPLE
    ./scripts/build-docs.ps1 -Check
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repoRoot 'infra/modules/catalog.json'
$docPath = Join-Path $repoRoot 'docs/modules.md'

if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "Module catalog '$catalogPath' is missing. Run ./scripts/build-catalog.ps1 first."
}
if (-not (Test-Path -LiteralPath $docPath -PathType Leaf)) {
    throw "Documentation file '$docPath' is missing."
}

$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

function Format-MarkdownCell {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return '–' }
    $items = @($Value | Where-Object { $null -ne $_ -and [string] $_ -ne '' })
    if ($items.Count -eq 0) { return '–' }
    return (($items | ForEach-Object { '`' + [string] $_ + '`' }) -join ', ')
}

function New-ModuleTable {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $lines = @(
        '| Module | Kind | Abbreviation | Profiles | Feature flag | Providers |',
        '|---|---|---|---|---|---|'
    )

    foreach ($module in ($catalog.modules | Sort-Object -Property name)) {
        $abbreviations = @($module.abbreviation) + @($module.additionalAbbreviations)
        $lines += '| [`{0}`](../infra/modules/{0}/README.md) | {1} | {2} | {3} | {4} | {5} |' -f `
            $module.name,
            $module.kind,
        (Format-MarkdownCell $abbreviations),
        (Format-MarkdownCell $module.profiles),
        (Format-MarkdownCell $module.featureFlag),
        (Format-MarkdownCell $module.providers)
    }

    return [string[]] $lines
}

function New-PrivateEndpointTable {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $lines = @(
        '| Module | Zone key | Private DNS zone | Group IDs | Link suffix |',
        '|---|---|---|---|---|'
    )

    $rows = 0
    foreach ($module in ($catalog.modules | Sort-Object -Property name)) {
        foreach ($endpoint in @($module.privateEndpoints)) {
            $lines += '| `{0}` | `{1}` | `{2}` | {3} | `{4}` |' -f `
                $module.name,
                $endpoint.zoneKey,
                $endpoint.dnsZone,
            (Format-MarkdownCell $endpoint.groupIds),
            $endpoint.linkSuffix
            $rows++
        }
    }

    if ($rows -eq 0) {
        return [string[]] @('No catalog module declares a private endpoint.')
    }
    return [string[]] $lines
}

function Update-GeneratedSection {
    <#
    .SYNOPSIS
        Replaces the content between a pair of marker comments.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Marker,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Lines
    )

    $begin = "<!-- BEGIN GENERATED: $Marker -->"
    $end = "<!-- END GENERATED: $Marker -->"

    $startIndex = $Content.IndexOf($begin, [StringComparison]::Ordinal)
    $endIndex = $Content.IndexOf($end, [StringComparison]::Ordinal)
    if ($startIndex -lt 0 -or $endIndex -lt 0 -or $endIndex -lt $startIndex) {
        throw "docs/modules.md is missing the '$Marker' generated-section markers."
    }

    $body = ($Lines -join "`n")
    $replacement = "$begin`n$body`n$end"
    return $Content.Substring(0, $startIndex) + $replacement +
    $Content.Substring($endIndex + $end.Length)
}

$original = (Get-Content -LiteralPath $docPath -Raw) -replace "`r`n", "`n"
$updated = $original
$updated = Update-GeneratedSection -Content $updated -Marker 'module-table' -Lines (New-ModuleTable)
$updated = Update-GeneratedSection -Content $updated -Marker 'private-endpoint-table' -Lines (New-PrivateEndpointTable)

if ($updated -ceq $original) {
    Write-Verbose "Unchanged: $docPath"
    if ($Check) { return }

    return [pscustomobject] @{
        Path    = $docPath
        Modules = @($catalog.modules).Count
        Changed = $false
    }
}

if ($Check) {
    throw "Generated sections in '$docPath' are stale. Run ./scripts/build-docs.ps1 and commit the result."
}

if ($PSCmdlet.ShouldProcess($docPath, 'Write generated documentation sections')) {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($docPath, $updated, $utf8NoBom)
    Write-Verbose "Wrote: $docPath"
}

[pscustomobject] @{
    Path    = $docPath
    Modules = @($catalog.modules).Count
    Changed = $true
}
