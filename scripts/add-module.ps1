<#
.SYNOPSIS
    Wires a catalog module into a project's infra/main.bicep.

.DESCRIPTION
    Generates the feature flag, resource name variables, module block and
    outputs for a catalog module, following the conventions already used in
    infra/main.bicep, and inserts the module block between the

        // #region modules
        // #endregion modules

    markers.

    The operation is idempotent: a module that is already wired in is reported
    and left untouched. When the markers are absent, which is the case in a
    project that maintains its own main.bicep, the full snippet is printed for
    the caller to paste instead of the file being edited.

    The declarations that must sit next to their peers - the feature flag, the
    name variables and the outputs - are always printed rather than injected,
    because their correct position depends on the surrounding file.

.PARAMETER Module
    Catalog module name, matching a folder under infra/modules/.

.PARAMETER Path
    Project root to modify. Defaults to this repository.

.PARAMETER PrintOnly
    Print the snippet without editing, regardless of markers.

.EXAMPLE
    ./scripts/add-module.ps1 -Module service-bus

.EXAMPLE
    ./scripts/add-module.ps1 -Module service-bus -Path D:\src\my-project -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $Module,

    [string] $Path,

    [switch] $PrintOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-CamelCase {
    param([Parameter(Mandatory)][string] $Value)

    $parts = @($Value -split '[-_]+' | Where-Object { $_ })
    $head = $parts[0].Substring(0, 1).ToLowerInvariant() + $parts[0].Substring(1)
    $tail = $parts | Select-Object -Skip 1 | ForEach-Object {
        $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
    }
    return ($head + ($tail -join ''))
}

function ConvertTo-PascalCase {
    param([Parameter(Mandatory)][string] $Value)

    $camel = ConvertTo-CamelCase -Value $Value
    return $camel.Substring(0, 1).ToUpperInvariant() + $camel.Substring(1)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = $repoRoot
}
$Path = (Resolve-Path -LiteralPath $Path).Path

$catalogPath = Join-Path $repoRoot 'infra/modules/catalog.json'
if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "Module catalog '$catalogPath' is missing. Run ./scripts/build-catalog.ps1 first."
}

$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$entry = $catalog.modules | Where-Object { $_.name -eq $Module } | Select-Object -First 1
if (-not $entry) {
    $available = ($catalog.modules | ForEach-Object { $_.name }) -join ', '
    throw "Module '$Module' is not in the catalog. Available modules: $available"
}

$mainBicepPath = Join-Path $Path 'infra/main.bicep'
if (-not (Test-Path -LiteralPath $mainBicepPath)) {
    throw "'$mainBicepPath' was not found. Run this from a project that has infra/main.bicep."
}

$camel = ConvertTo-CamelCase -Value $Module
$content = Get-Content -LiteralPath $mainBicepPath -Raw
$normalized = $content -replace "`r`n", "`n"
if ($normalized -match "(?m)^module\s+$([regex]::Escape($camel))\s") {
    return [pscustomobject] @{
        Module = $Module; Path = $mainBicepPath; Action = 'AlreadyPresent'
        Changed = $false; Snippet = ''
    }
}
$pascal = ConvertTo-PascalCase -Value $Module
$upper = ($Module -replace '-', '_').ToUpperInvariant()
$endpoints = @($entry.privateEndpoints)

# Prefer the symbolic abbreviations key over a literal, so a project that
# renames an abbreviation only has to change infra/core/abbreviations.json.
$abbreviationsPath = Join-Path $repoRoot 'infra/core/abbreviations.json'
$abbreviationToken = "'$($entry.abbreviation)'"
$abbreviationWarning = $null
if (Test-Path -LiteralPath $abbreviationsPath) {
    $abbreviations = Get-Content -LiteralPath $abbreviationsPath -Raw | ConvertFrom-Json
    $key = $abbreviations.PSObject.Properties |
        Where-Object { $_.Value -eq $entry.abbreviation } |
        Select-Object -First 1 -ExpandProperty Name
    if ($key) {
        $abbreviationToken = "abbreviations.$key"
    }
    else {
        $abbreviationWarning = "Abbreviation '$($entry.abbreviation)' is not in infra/core/abbreviations.json. Add it and replace the literal in the generated name variable."
    }
}

$nameLines = [System.Collections.Generic.List[string]]::new()
switch ($entry.nameRule) {
    'global' {
        $nameLines.Add("var $($camel)Name = globalName($abbreviationToken, locationCode, subscriptionCode, environmentName, shortUniqueSuffix, '-', 24)")
    }
    'globalCompact' {
        $nameLines.Add("var $($camel)Name = globalName($abbreviationToken, locationCode, subscriptionCode, environmentName, shortUniqueSuffix, '', 24)")
    }
    'hostname' {
        $nameLines.Add("var $($camel)Name = shortName('$($entry.abbreviation)', environmentName, shortUniqueSuffix, 15)")
    }
    default {
        $nameLines.Add("var $($camel)Name = azName($abbreviationToken, tenantCode, locationCode, subscriptionCode, environmentName, '')")
    }
}

$moduleParamLines = [System.Collections.Generic.List[string]]::new()
$moduleParamLines.Add("    name: $($camel)Name")

$single = $endpoints.Count -eq 1
foreach ($endpoint in $endpoints) {
    $suffix = [string] $endpoint.linkSuffix
    $zoneKey = [string] $endpoint.zoneKey

    # A module with one endpoint keeps the plain parameter names produced by
    # scripts/new-module.ps1. A module with several prefixes them, matching the
    # storage module.
    if ($single) {
        $peNameVar = "$($camel)PrivateEndpointName"
        $peNicVar = "$($camel)PrivateEndpointNicName"
        $nameParam = 'privateEndpointName'
        $nicParam = 'privateEndpointNetworkInterfaceName'
        $zoneParam = 'privateDnsZoneId'
    }
    else {
        $peNameVar = "$($suffix)PrivateEndpointName"
        $peNicVar = "$($suffix)PrivateEndpointNicName"
        $nameParam = "$($suffix)PrivateEndpointName"
        $nicParam = "$($suffix)PrivateEndpointNetworkInterfaceName"
        $zoneParam = "$($suffix)PrivateDnsZoneId"
    }

    $nameLines.Add("var $peNameVar = azName(abbreviations.privateEndpoint, tenantCode, locationCode, subscriptionCode, environmentName, '$suffix')")
    $nameLines.Add("var $peNicVar = azName(abbreviations.privateEndpointNetworkInterface, tenantCode, locationCode, subscriptionCode, environmentName, '$suffix')")

    $moduleParamLines.Add("    $($nameParam): $peNameVar")
    $moduleParamLines.Add("    $($nicParam): $peNicVar")
    $moduleParamLines.Add("    $($zoneParam): deployNetwork ? privateDns!.outputs.zoneIds.$zoneKey : ''")
}

$moduleParamLines.Add('    location: location')
$moduleParamLines.Add('    tags: tags')
if ($endpoints.Count -gt 0) {
    $moduleParamLines.Add("    privateEndpointSubnetId: deployNetwork ? network!.outputs.privateEndpointSubnetId : ''")
}

# Ask the compiler for the actual target module contract, not a regex guess at
# defaults or an assumption that composites expose resource-style outputs.
$targetModule = Join-Path $Path "infra/modules/$Module/main.bicep"
if (-not (Test-Path -LiteralPath $targetModule)) {
    throw "Copy the complete '$Module' module and its core dependencies to '$targetModule' before wiring it."
}
$compiledJson = & az bicep build --file $targetModule --stdout
if ($LASTEXITCODE -ne 0) { throw "Unable to compile '$targetModule'; no wiring was changed." }
$contract = ($compiledJson -join "`n") | ConvertFrom-Json -AsHashtable
$bindings = @($moduleParamLines | ForEach-Object { ($_ -split ':', 2)[0].Trim() })
$missing = @($contract.parameters.Keys | Where-Object {
    -not $contract.parameters[$_].Contains('defaultValue') -and $_ -notin $bindings
} | Sort-Object)
$unknown = @($bindings | Where-Object { -not $contract.parameters.Contains($_) })
$missingOutputs = @('id', 'name' | Where-Object {
    -not $contract.Contains('outputs') -or -not $contract.outputs.Contains($_) -or $contract.outputs[$_].type -ne 'string'
})
if ($missing.Count -or $unknown.Count -or $missingOutputs.Count -or $entry.kind -ne 'resource') {
    throw "Cannot automatically wire '$Module'. Required inputs needing explicit bindings: [$($missing -join ', ')]. Unsupported generated inputs: [$($unknown -join ', ')]. Missing string outputs: [$($missingOutputs -join ', ')]. Composite modules require manual composition. Use infra/modules/$Module/README.md and its main.bicep to bind these inputs and supported outputs manually; no files were changed."
}

$condition = if ($entry.featureFlag) { " = if (deploy$pascal)" } else { ' =' }

$moduleBlock = @"
module $camel './modules/$Module/main.bicep'$condition {
  name: '$Module'
  scope: resourceGroup
  params: {
$($moduleParamLines -join "`n")
  }
}
"@

$flagLine = if ($entry.featureFlag) {
    "var deploy$pascal = bool(featureSettings.$($entry.featureFlag))"
}
else {
    $null
}

$outputExpressionId = if ($entry.featureFlag) {
    "deploy$pascal ? $camel!.outputs.id : ''"
}
else {
    "$camel.outputs.id"
}
$outputExpressionName = if ($entry.featureFlag) {
    "deploy$pascal ? $camel!.outputs.name : ''"
}
else {
    "$camel.outputs.name"
}
$outputBlock = @"
output AZURE_$($upper)_ID string = $outputExpressionId
output AZURE_$($upper)_NAME string = $outputExpressionName
"@

$snippetSections = [System.Collections.Generic.List[string]]::new()
if ($flagLine) {
    $snippetSections.Add("// 1. Feature flag - place next to the other deploy* variables.`n//    Add '$($entry.featureFlag)' to featureSettings with default false and`n//    explicitly wire the same opt-in into preflight's featureSettings.`n$flagLine")
}
$snippetSections.Add("// 2. Resource names - place next to the other name variables.`n$($nameLines -join "`n")")
$snippetSections.Add("// 3. Module - place inside the // #region modules block.`n$moduleBlock")
$snippetSections.Add("// 4. Outputs - place next to the other outputs.`n$outputBlock")
$snippet = $snippetSections -join "`n`n"

$content = Get-Content -LiteralPath $mainBicepPath -Raw
$normalized = $content -replace "`r`n", "`n"

if ($normalized -match "(?m)^module\s+$([regex]::Escape($camel))\s") {
    Write-Verbose "Module '$Module' is already wired into '$mainBicepPath'."
    return [pscustomobject] @{
        Module  = $Module
        Path    = $mainBicepPath
        Action  = 'AlreadyPresent'
        Changed = $false
        Snippet = $snippet
    }
}

$startMarker = '// #region modules'
$endMarker = '// #endregion modules'
$hasMarkers = $normalized.Contains($startMarker) -and $normalized.Contains($endMarker)

if ($PrintOnly -or -not $hasMarkers) {
    $reason = if ($PrintOnly) {
        '-PrintOnly was requested'
    }
    else {
        "'$mainBicepPath' has no '$startMarker' / '$endMarker' markers"
    }

    Write-Warning "Not editing the template because $reason. Add the declarations below by hand."
    Write-Output $snippet

    return [pscustomobject] @{
        Module  = $Module
        Path    = $mainBicepPath
        Action  = 'PrintedSnippet'
        Changed = $false
        Snippet = $snippet
    }
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.AddRange([string[]] ($normalized.Split("`n")))

$endIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq $endMarker) {
        $endIndex = $i
        break
    }
}
if ($endIndex -lt 0) {
    throw "Unable to locate '$endMarker' in '$mainBicepPath'."
}

$insertion = [System.Collections.Generic.List[string]]::new()
$insertion.Add('')
$insertion.AddRange([string[]] ($moduleBlock.Split("`n")))
$lines.InsertRange($endIndex, $insertion)

$result = (($lines -join "`n").TrimEnd()) + "`n"

if ($PSCmdlet.ShouldProcess($mainBicepPath, "Wire in module '$Module'")) {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($mainBicepPath, $result, $utf8NoBom)
}

if ($abbreviationWarning) {
    Write-Warning $abbreviationWarning
}

Write-Warning "The module block was inserted. Add the remaining declarations by hand - they must sit next to their peers:"
Write-Output ''
if ($flagLine) {
    Write-Output $flagLine
}
Write-Output ($nameLines -join "`n")
Write-Output ''
Write-Output $outputBlock

[pscustomobject] @{
    Module  = $Module
    Path    = $mainBicepPath
    Action  = 'Inserted'
    Changed = $true
    Snippet = $snippet
}
