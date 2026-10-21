<#
.SYNOPSIS
    Regenerates the module catalog index and the private DNS zone catalog from
    module metadata.

.DESCRIPTION
    Every module under infra/modules/<name>/ owns a metadata.json describing its
    contract: providers, profiles, private endpoints, roles and preflight
    requirements. Three artefacts are derived from those files and must never be
    hand-edited:

      infra/modules/catalog.json      the index consumed by scripts and docs
      infra/core/private-dns-zones.json  the zone list consumed by the
                                         private-dns Bicep module
      docs/modules.md                 the human-readable catalog (see
                                      scripts/build-docs.ps1)

    Run with -Check to fail when the generated files are stale, which is what
    the test suite and CI do.

.PARAMETER Check
    Compare the generated content against what is on disk and throw when they
    differ, instead of writing.

.EXAMPLE
    ./scripts/build-catalog.ps1

.EXAMPLE
    ./scripts/build-catalog.ps1 -Check
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulesRoot = Join-Path $repoRoot 'infra/modules'
$catalogPath = Join-Path $modulesRoot 'catalog.json'
$dnsZonesPath = Join-Path $repoRoot 'infra/core/private-dns-zones.json'

$requiredKeys = @(
    'name', 'displayName', 'description', 'kind', 'abbreviation',
    'featureFlag', 'profiles', 'providers', 'privateEndpoints',
    'roles', 'nameRule', 'preflight'
)
$knownKinds = @('resource', 'composite')
$knownProfiles = @('core', 'private', 'full')
$knownNameRules = @('regional', 'global', 'globalCompact', 'hostname', 'fixed')

function Read-ModuleMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        $metadata = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Unable to parse module metadata '$Path': $($_.Exception.Message)"
    }

    foreach ($key in $requiredKeys) {
        if (-not $metadata.ContainsKey($key)) {
            throw "Module metadata '$Path' is missing the required key '$key'."
        }
    }

    foreach ($key in @('name', 'displayName', 'description', 'kind', 'nameRule')) {
        if ($metadata[$key] -isnot [string]) { throw "Module metadata '$Path': '$key' must be a string." }
    }
    if ($null -ne $metadata.featureFlag -and
        ($metadata.featureFlag -isnot [string] -or $metadata.featureFlag -cnotmatch '^[a-z][A-Za-z0-9]*$')) {
        throw "Module metadata '$Path': 'featureFlag' must be null or a camelCase feature name."
    }
    foreach ($key in @('profiles', 'providers', 'privateEndpoints', 'roles')) {
        if ($metadata[$key] -isnot [array]) { throw "Module metadata '$Path': '$key' must be an array." }
    }
    if ($metadata.preflight -isnot [System.Collections.IDictionary] -or
        -not $metadata.preflight.Contains('checks') -or
        $metadata.preflight.checks -isnot [array] -or
        -not $metadata.preflight.Contains('requiresOperatorPrincipals') -or
        $metadata.preflight.requiresOperatorPrincipals -isnot [bool]) {
        throw "Module metadata '$Path': preflight requires a checks array and a boolean requiresOperatorPrincipals."
    }
    foreach ($endpoint in $metadata.privateEndpoints) {
        foreach ($key in @('zoneKey', 'dnsZone', 'linkSuffix', 'connectionName')) {
            if ($endpoint -isnot [System.Collections.IDictionary] -or
                -not $endpoint.Contains($key) -or [string]::IsNullOrWhiteSpace([string] $endpoint[$key])) {
                throw "Module metadata '$Path': privateEndpoints requires '$key'."
            }
        }
        if (-not $endpoint.Contains('groupIds') -or $endpoint.groupIds -isnot [array] -or $endpoint.groupIds.Count -eq 0) {
            throw "Module metadata '$Path': privateEndpoints requires a nonempty groupIds array."
        }
    }
    foreach ($role in $metadata.roles) {
        if ($role -isnot [System.Collections.IDictionary] -or -not $role.Contains('name') -or -not $role.Contains('id')) {
            throw "Module metadata '$Path': each role requires name and id."
        }
    }

    $folderName = Split-Path -Leaf (Split-Path -Parent $Path)
    if ([string] $metadata['name'] -cne $folderName) {
        throw "Module metadata '$Path' declares name '$($metadata['name'])' but lives in folder '$folderName'."
    }

    if ($knownKinds -notcontains [string] $metadata['kind']) {
        throw "Module '$folderName' declares unknown kind '$($metadata['kind'])'; expected one of: $($knownKinds -join ', ')."
    }

    if ($knownNameRules -notcontains [string] $metadata['nameRule']) {
        throw "Module '$folderName' declares unknown nameRule '$($metadata['nameRule'])'; expected one of: $($knownNameRules -join ', ')."
    }

    # Only a module whose resource names are dictated by the service itself may
    # skip the abbreviation; everything else has to claim one.
    if ([string]::IsNullOrWhiteSpace([string] $metadata['abbreviation']) -and [string] $metadata['nameRule'] -ne 'fixed') {
        throw "Module '$folderName' must declare an abbreviation unless its nameRule is 'fixed'."
    }

    if (@($metadata['profiles']).Count -eq 0) {
        throw "Module '$folderName' must declare at least one profile."
    }

    foreach ($profileName in $metadata['profiles']) {
        if ($knownProfiles -notcontains [string] $profileName) {
            throw "Module '$folderName' declares unknown profile '$profileName'; expected one of: $($knownProfiles -join ', ')."
        }
    }

    return $metadata
}

function ConvertTo-CatalogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Metadata
    )

    # Ordered so the generated JSON is stable across runs and diffs cleanly.
    $entry = [ordered] @{
        name             = [string] $Metadata['name']
        displayName      = [string] $Metadata['displayName']
        description      = [string] $Metadata['description']
        kind             = [string] $Metadata['kind']
        abbreviation     = $Metadata['abbreviation']
        # Composite modules name more than one resource. The extras are listed
        # so abbreviation uniqueness and the docs table stay complete.
        additionalAbbreviations = @(if ($Metadata.Contains('additionalAbbreviations')) { $Metadata['additionalAbbreviations'] } else { @() })
        featureFlag      = $Metadata['featureFlag']
        profiles         = @($Metadata['profiles'] | Sort-Object)
        providers        = @($Metadata['providers'] | Sort-Object)
        nameRule         = [string] $Metadata['nameRule']
        path             = "infra/modules/$($Metadata['name'])/main.bicep"
        privateEndpoints = @()
        roles            = @()
        preflight        = [ordered] @{
            checks                     = @($Metadata['preflight']['checks'])
            requiresOperatorPrincipals = [bool] $Metadata['preflight']['requiresOperatorPrincipals']
        }
    }

    foreach ($endpoint in $Metadata['privateEndpoints']) {
        $entry['privateEndpoints'] += , ([ordered] @{
                zoneKey        = [string] $endpoint['zoneKey']
                groupIds       = @($endpoint['groupIds'])
                dnsZone        = [string] $endpoint['dnsZone']
                linkSuffix     = [string] $endpoint['linkSuffix']
                connectionName = [string] $endpoint['connectionName']
            })
    }

    foreach ($role in $Metadata['roles']) {
        $entry['roles'] += , ([ordered] @{
                name = [string] $role['name']
                id   = [string] $role['id']
            })
    }

    return $entry
}

function Write-GeneratedJson {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Content
    )

    $json = ($Content | ConvertTo-Json -Depth 12).TrimEnd() + "`n"
    $json = $json -replace "`r`n", "`n"

    $existing = $null
    if (Test-Path -LiteralPath $Path) {
        $existing = (Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n"
    }

    if ($existing -ceq $json) {
        Write-Verbose "Unchanged: $Path"
        return $false
    }

    if ($Check) {
        throw "Generated file '$Path' is stale. Run ./scripts/build-catalog.ps1 and commit the result."
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write generated catalog')) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
        Write-Verbose "Wrote: $Path"
    }

    return $true
}

if (-not (Test-Path -LiteralPath $modulesRoot)) {
    throw "Module root '$modulesRoot' does not exist."
}

$metadataFiles = Get-ChildItem -LiteralPath $modulesRoot -Directory |
    Where-Object { -not $_.Name.StartsWith('.') } |
    Sort-Object -Property Name |
    ForEach-Object { Join-Path $_.FullName 'metadata.json' }

$missing = @($metadataFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    throw "Every module folder must contain metadata.json. Missing: $($missing -join ', ')"
}

$modules = @()
foreach ($file in $metadataFiles) {
    $metadata = Read-ModuleMetadata -Path $file

    $moduleDir = Split-Path -Parent $file
    foreach ($companion in @('main.bicep', 'README.md')) {
        $companionPath = Join-Path $moduleDir $companion
        if (-not (Test-Path -LiteralPath $companionPath)) {
            throw "Module '$($metadata['name'])' is missing required file '$companion'."
        }
    }

    $modules += , $metadata
}

$abbreviationOwners = @{}
foreach ($metadata in $modules) {
    $abbreviation = [string] $metadata['abbreviation']
    if ($abbreviationOwners.ContainsKey($abbreviation)) {
        throw "Abbreviation '$abbreviation' is claimed by both '$($abbreviationOwners[$abbreviation])' and '$($metadata['name'])'. Abbreviations must be unique across the catalog."
    }
    $abbreviationOwners[$abbreviation] = [string] $metadata['name']
}

$zoneOwners = @{}
$zones = @()
foreach ($metadata in $modules) {
    foreach ($endpoint in $metadata['privateEndpoints']) {
        $zoneKey = [string] $endpoint['zoneKey']
        if ($zoneOwners.ContainsKey($zoneKey)) {
            throw "Private DNS zone key '$zoneKey' is claimed by both '$($zoneOwners[$zoneKey])' and '$($metadata['name'])'. Zone keys must be unique across the catalog."
        }
        $zoneOwners[$zoneKey] = [string] $metadata['name']

        $zones += , ([ordered] @{
                key        = $zoneKey
                module     = [string] $metadata['name']
                zone       = [string] $endpoint['dnsZone']
                linkSuffix = [string] $endpoint['linkSuffix']
            })
    }
}

if ($zones.Count -eq 0) {
    throw 'No module declares a private endpoint. The private-dns module would have nothing to deploy.'
}

$catalog = [ordered] @{
    '$comment' = 'GENERATED by scripts/build-catalog.ps1 from infra/modules/*/metadata.json. Do not edit by hand.'
    generator  = 'scripts/build-catalog.ps1'
    modules    = @($modules | ForEach-Object { ConvertTo-CatalogEntry -Metadata $_ })
}

$catalogChanged = Write-GeneratedJson -Path $catalogPath -Content $catalog
$zonesChanged = Write-GeneratedJson -Path $dnsZonesPath -Content @($zones)

if ($Check) {
    Write-Verbose 'Generated catalog files are up to date.'
    return
}

[pscustomobject] @{
    Modules       = $modules.Count
    Zones         = $zones.Count
    CatalogPath   = $catalogPath
    DnsZonesPath  = $dnsZonesPath
    Changed       = ($catalogChanged -or $zonesChanged)
}
