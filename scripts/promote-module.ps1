<#
.SYNOPSIS
    Promotes a module proven in another repository into this template's catalog.

.DESCRIPTION
    This is the enrichment path. A module that has earned its keep in a real
    project is copied into infra/modules/, validated against the catalog
    contract, and staged for review.

    Promotion refuses on any contract violation, so a module that does not
    conform never reaches the catalog:

      * the source must contain main.bicep, metadata.json and README.md
      * metadata.json must satisfy the catalog schema, which
        scripts/build-catalog.ps1 enforces
      * the abbreviation and every private DNS zone key must be unique across
        the catalog
      * main.bicep must declare the required params and, for kind 'resource',
        the required outputs
      * main.bicep must build and lint cleanly
      * no TODO placeholder may remain

.PARAMETER From
    Path to the module folder to promote. The folder name becomes the module
    name unless -Name is supplied.

.PARAMETER Name
    Override the catalog module name.

.PARAMETER Force
    Overwrite an existing catalog module of the same name.

.PARAMETER NoStage
    Skip 'git add' of the promoted files.

.EXAMPLE
    ./scripts/promote-module.ps1 -From D:\src\foundry-notifications-tests\infra\modules\service-bus

.EXAMPLE
    ./scripts/promote-module.ps1 -From ..\other-repo\infra\modules\event-grid -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $From,

    [string] $Name,

    [switch] $Force,

    [switch] $NoStage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $From -PathType Container)) {
    throw "Source module folder '$From' was not found."
}
$source = (Resolve-Path -LiteralPath $From).Path

if ([string]::IsNullOrWhiteSpace($Name)) {
    $Name = Split-Path -Leaf $source
}
if ($Name -notmatch '^[a-z][a-z0-9]*(-[a-z0-9]+)*$') {
    throw "Module name '$Name' must be lower-case kebab-case, for example 'service-bus'."
}

$modulesRoot = Join-Path $repoRoot 'infra/modules'
$destination = Join-Path $modulesRoot $Name

if ($destination -eq $source) {
    throw "Source and destination are the same folder. Nothing to promote."
}
if ((Test-Path -LiteralPath $destination) -and -not $Force) {
    throw "Module '$Name' already exists in the catalog. Re-run with -Force to replace it."
}

# ---------------------------------------------------------------------------
# Pre-copy checks against the source, so a broken module never lands.
# ---------------------------------------------------------------------------

$violations = [System.Collections.Generic.List[string]]::new()

foreach ($required in @('main.bicep', 'metadata.json', 'README.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $required) -PathType Leaf)) {
        $violations.Add("missing required file '$required'")
    }
}
if ($violations.Count -gt 0) {
    throw "Module '$Name' violates the catalog contract:`n  - $($violations -join "`n  - ")"
}

$metadataPath = Join-Path $source 'metadata.json'
try {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
}
catch {
    throw "metadata.json in '$source' is not valid JSON: $($_.Exception.Message)"
}

if ($metadata.name -ne $Name) {
    $violations.Add("metadata.json name '$($metadata.name)' does not match the module folder '$Name'")
}

$bicepPath = Join-Path $source 'main.bicep'
$bicep = Get-Content -LiteralPath $bicepPath -Raw

foreach ($param in @('name', 'location', 'tags')) {
    if ($bicep -notmatch "(?m)^param\s+$param\s") {
        $violations.Add("main.bicep does not declare the required param '$param'")
    }
}

$kind = if ($metadata.PSObject.Properties.Name -contains 'kind') { [string] $metadata.kind } else { 'resource' }
if ($kind -eq 'resource') {
    foreach ($outputName in @('id', 'name')) {
        if ($bicep -notmatch "(?m)^output\s+$outputName\s+string\s*=") {
            $violations.Add("main.bicep does not declare the required output '$outputName'")
        }
    }
}

if ($bicep -match 'TODO') {
    $violations.Add('main.bicep still contains a TODO placeholder')
}

$readme = Get-Content -LiteralPath (Join-Path $source 'README.md') -Raw
if ($readme -match 'TODO') {
    $violations.Add('README.md still contains a TODO placeholder')
}

# Uniqueness against the current catalog, excluding the module being replaced.
$catalogPath = Join-Path $modulesRoot 'catalog.json'
if (Test-Path -LiteralPath $catalogPath) {
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    $others = @($catalog.modules | Where-Object { $_.name -ne $Name })

    $clash = $others | Where-Object { $_.abbreviation -eq $metadata.abbreviation } | Select-Object -First 1
    if ($clash) {
        $violations.Add("abbreviation '$($metadata.abbreviation)' is already used by module '$($clash.name)'")
    }

    $takenZoneKeys = @{}
    foreach ($other in $others) {
        foreach ($endpoint in @($other.privateEndpoints)) {
            $takenZoneKeys[[string] $endpoint.zoneKey] = $other.name
        }
    }
    if ($metadata.PSObject.Properties.Name -contains 'privateEndpoints') {
        foreach ($endpoint in @($metadata.privateEndpoints)) {
            $zoneKey = [string] $endpoint.zoneKey
            if ($takenZoneKeys.ContainsKey($zoneKey)) {
                $violations.Add("private DNS zone key '$zoneKey' is already used by module '$($takenZoneKeys[$zoneKey])'")
            }
        }
    }
}

if ($violations.Count -gt 0) {
    throw "Module '$Name' violates the catalog contract:`n  - $($violations -join "`n  - ")"
}

# Validate a complete candidate repository before touching any existing file.
# Its directory layout preserves relative Bicep imports and the real gates.
$staging = Join-Path $repoRoot ('.promotion-' + [guid]::NewGuid().ToString('N'))
$generatedFiles = @('infra/modules/catalog.json', 'infra/core/private-dns-zones.json', 'docs/modules.md')
$originalGenerated = @{}
$backup = Join-Path $staging 'original-module'
$replacementStarted = $false
$hadOriginal = Test-Path -LiteralPath $destination
try {
    foreach ($required in @('scripts/build-catalog.ps1', 'scripts/build-docs.ps1', 'tests/run-tests.ps1', 'docs/modules.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $required))) {
            throw "Promotion requires '$required'. Restore the catalog tooling and conformance suite before promoting."
        }
    }
    New-Item -ItemType Directory -Path $staging -Force -WhatIf:$false | Out-Null
    foreach ($folder in @('infra', 'scripts', 'tests', 'docs')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $folder) -Destination $staging -Recurse -Force -WhatIf:$false
    }
    $candidate = Join-Path $staging "infra/modules/$Name"
    if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Recurse -Force -WhatIf:$false
    }
    New-Item -ItemType Directory -Path $candidate -Force -WhatIf:$false | Out-Null
    foreach ($file in @('main.bicep', 'metadata.json', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $source $file) -Destination $candidate -Force -WhatIf:$false
    }
    $catalogResult = & (Join-Path $staging 'scripts/build-catalog.ps1') -WhatIf:$false
    & (Join-Path $staging 'scripts/build-docs.ps1') -WhatIf:$false | Out-Null
    $stagedBicepPath = Join-Path $candidate 'main.bicep'
    $buildOutput = & az bicep build --file $stagedBicepPath --stdout 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Module '$Name' does not build:`n$buildOutput"
    }
    $lintOutput = & az bicep lint --file $stagedBicepPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Module '$Name' does not lint cleanly:`n$lintOutput"
    }
    & (Join-Path $staging 'tests/run-tests.ps1') -Name catalog | Out-Null
    $testsPassed = $true

    if (-not $PSCmdlet.ShouldProcess($destination, "Promote module '$Name' into the catalog")) {
        return [pscustomobject] @{
            Module = $Name; Source = $source; Destination = $destination
            Action = 'WhatIf'; Changed = $false
        }
    }
    foreach ($relative in $generatedFiles) {
        $path = Join-Path $repoRoot $relative
        $originalGenerated[$relative] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null }
    }
    if ($hadOriginal) {
        Copy-Item -LiteralPath $destination -Destination $backup -Recurse -Force
    }
    $replacementStarted = $true
    if ($hadOriginal) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    Copy-Item -LiteralPath $candidate -Destination $destination -Recurse -Force
    foreach ($relative in $generatedFiles) {
        Copy-Item -LiteralPath (Join-Path $staging $relative) -Destination (Join-Path $repoRoot $relative) -Force
    }

    $staged = $false
    if (-not $NoStage) {
        & git -C $repoRoot add -- "infra/modules/$Name/main.bicep" `
            "infra/modules/$Name/metadata.json" "infra/modules/$Name/README.md" @generatedFiles
        if ($LASTEXITCODE -ne 0) { throw 'Unable to stage promotion; git add failed.' }
        $staged = $true
    }
}
catch {
    if ($replacementStarted) {
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force -WhatIf:$false
        }
        if ($hadOriginal) {
            Copy-Item -LiteralPath $backup -Destination $destination -Recurse -Force -WhatIf:$false
        }
        foreach ($relative in $generatedFiles) {
            $path = Join-Path $repoRoot $relative
            if ($null -eq $originalGenerated[$relative]) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -WhatIf:$false }
            }
            else {
                [IO.File]::WriteAllBytes($path, $originalGenerated[$relative])
            }
        }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -WhatIf:$false
    }
}

[pscustomobject] @{
    Module      = $Name
    Source      = $source
    Destination = $destination
    Action      = 'Promoted'
    Changed     = $true
    Zones       = $catalogResult.Zones
    Modules     = $catalogResult.Modules
    TestsPassed = $testsPassed
    Staged      = $staged
    NextSteps   = @(
        "Wire it into a project with ./scripts/add-module.ps1 -Module $Name",
        'Review the generated infra/modules/catalog.json and infra/core/private-dns-zones.json',
        './tests/run-tests.ps1'
    )
}
