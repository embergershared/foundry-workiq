<#
.SYNOPSIS
    Scaffolds a new catalog module that already conforms to the module contract.

.DESCRIPTION
    Creates infra/modules/<name>/ containing main.bicep, metadata.json, README.md
    and a test stub, then regenerates the catalog.

    The generated Bicep already satisfies the contract enforced by
    tests/catalog.tests.ps1:

      required params  : name, location, tags
      required outputs : id, name                        (kind 'resource' only)
      optional params  : privateEndpointSubnetId, privateDnsZoneId

    When both private endpoint parameters are empty the module deploys
    public-with-firewall; when they are set it calls core/private-endpoint.bicep.
    That is what lets one module body serve the core, private and full profiles.

.PARAMETER Name
    Kebab-case module name, which is also the folder name.

.PARAMETER Abbreviation
    Resource-type abbreviation used as the leading name segment.

.PARAMETER Provider
    One or more Azure resource provider namespaces the module deploys into.

.PARAMETER ResourceType
    Fully qualified resource type, such as Microsoft.ServiceBus/namespaces.

.PARAMETER ApiVersion
    API version for the resource type.

.PARAMETER Profiles
    Profiles the module belongs to. Defaults to all three.

.PARAMETER Kind
    'resource' for a single primary resource, 'composite' for a multi-resource
    module. Composite modules are exempt from the id/name output contract.

.PARAMETER PrivateEndpointGroupId
    Private link group ID, such as 'namespace'. Omit for a module with no
    private endpoint.

.PARAMETER PrivateDnsZone
    Private DNS zone, such as privatelink.servicebus.windows.net.

.PARAMETER NameRule
    Name class from infra/core/name-rules.json.

.EXAMPLE
    ./scripts/new-module.ps1 -Name service-bus -Abbreviation sbns -Provider Microsoft.ServiceBus `
        -ResourceType Microsoft.ServiceBus/namespaces -ApiVersion 2022-10-01-preview `
        -PrivateEndpointGroupId namespace -PrivateDnsZone privatelink.servicebus.windows.net
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]*(-[a-z0-9]+)*$')]
    [string] $Name,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{0,11}$')]
    [string] $Abbreviation,

    [Parameter(Mandatory)]
    [ValidatePattern('^Microsoft\.[A-Za-z]+$')]
    [string[]] $Provider,

    [Parameter(Mandatory)]
    [ValidatePattern('^Microsoft\.[A-Za-z]+/[A-Za-z][A-Za-z0-9/]*$')]
    [string] $ResourceType,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}(-preview)?$')]
    [string] $ApiVersion,

    [ValidateSet('core', 'private', 'full')]
    [string[]] $Profiles = @('core', 'private', 'full'),

    [ValidateSet('resource', 'composite')]
    [string] $Kind = 'resource',

    [string] $PrivateEndpointGroupId = '',

    [string] $PrivateDnsZone = '',

    [ValidateSet('regional', 'global', 'globalCompact', 'hostname', 'fixed')]
    [string] $NameRule = 'regional',

    [string] $Description = '',

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleDir = Join-Path $repoRoot "infra/modules/$Name"

if ((Test-Path -LiteralPath $moduleDir) -and -not $Force) {
    throw "Module '$Name' already exists at '$moduleDir'. Pass -Force to overwrite."
}

$hasPrivateEndpoint = -not [string]::IsNullOrWhiteSpace($PrivateEndpointGroupId)
if ($hasPrivateEndpoint -and [string]::IsNullOrWhiteSpace($PrivateDnsZone)) {
    throw 'PrivateDnsZone is required when PrivateEndpointGroupId is supplied.'
}

$displayName = (Get-Culture).TextInfo.ToTitleCase(($Name -replace '-', ' '))
if ([string]::IsNullOrWhiteSpace($Description)) {
    $Description = "$displayName resources for projects built from this template."
}

# camelCase zone key, matching the existing keyVault/blob/file convention.
$parts = $Name.Split('-')
$zoneKey = $parts[0] + (($parts | Select-Object -Skip 1 | ForEach-Object {
            $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
        }) -join '')

function Write-ModuleFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Content
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Create')) {
        $normalized = ($Content -replace "`r`n", "`n").TrimEnd() + "`n"
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
    }
}

if ($PSCmdlet.ShouldProcess($moduleDir, 'Create module folder')) {
    $null = New-Item -ItemType Directory -Path $moduleDir -Force
}

# --------------------------------------------------------------------------
# main.bicep
# --------------------------------------------------------------------------

$peParams = if ($hasPrivateEndpoint) {
    @"

@description('Private endpoint name. Ignored when privateEndpointSubnetId is empty.')
param privateEndpointName string = ''

@description('Private endpoint network interface name. Ignored when privateEndpointSubnetId is empty.')
param privateEndpointNetworkInterfaceName string = ''

@description('Subnet hosting the private endpoint. Empty deploys the resource public with a deny-by-default firewall.')
param privateEndpointSubnetId string = ''

@description('Private DNS zone for $PrivateDnsZone. Empty deploys the resource public with a deny-by-default firewall.')
param privateDnsZoneId string = ''
"@
}
else {
    ''
}

$peVar = if ($hasPrivateEndpoint) {
    @'

// One module body serves every profile: private only when the caller supplies
// both a subnet and a DNS zone, otherwise public with a deny-by-default firewall.
var usePrivateEndpoint = !empty(privateEndpointSubnetId) && !empty(privateDnsZoneId)

'@
}
else {
    "`n"
}

$peBody = if ($hasPrivateEndpoint) {
    @"

module privateEndpoint '../../core/private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '`${name}-private-endpoint'
  params: {
    name: privateEndpointName
    networkInterfaceName: privateEndpointNetworkInterfaceName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateDnsZoneId: privateDnsZoneId
    privateLinkServiceId: $($Name -replace '-', '').id
    groupIds: [
      '$PrivateEndpointGroupId'
    ]
    connectionName: '$Name'
  }
}
"@
}
else {
    ''
}

$symbol = ($Name -replace '-', '')
$publicAccess = if ($hasPrivateEndpoint) {
    "    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'`n"
}
else {
    ''
}

$bicep = @"
// $displayName
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// TODO: replace the placeholder properties below with the real resource shape,
// then run ./scripts/build-catalog.ps1 and ./tests/run-tests.ps1.

@description('Resource name. Build it with the exported functions in infra/core/naming.bicep.')
param name string

@description('Azure region.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}
$peParams
$peVar
resource $symbol '$ResourceType@$ApiVersion' = {
  name: name
  location: location
  tags: tags
  properties: {
$publicAccess  }
}
$peBody

@description('Resource ID.')
output id string = $symbol.id

@description('Resource name.')
output name string = $symbol.name
"@

Write-ModuleFile -Path (Join-Path $moduleDir 'main.bicep') -Content $bicep

# --------------------------------------------------------------------------
# metadata.json
# --------------------------------------------------------------------------

$privateEndpoints = @()
if ($hasPrivateEndpoint) {
    $privateEndpoints += , ([ordered] @{
            zoneKey        = $zoneKey
            groupIds       = @($PrivateEndpointGroupId)
            dnsZone        = $PrivateDnsZone
            linkSuffix     = $Abbreviation
            connectionName = $Name
        })
}

$metadata = [ordered] @{
    name             = $Name
    displayName      = $displayName
    description      = $Description
    kind             = $Kind
    abbreviation     = $Abbreviation
    featureFlag      = $zoneKey
    profiles         = @($Profiles | Sort-Object -Unique)
    providers        = @($Provider | Sort-Object -Unique)
    privateEndpoints = $privateEndpoints
    roles            = @()
    nameRule         = $NameRule
    preflight        = [ordered] @{
        checks                     = @()
        requiresOperatorPrincipals = $false
    }
}

Write-ModuleFile -Path (Join-Path $moduleDir 'metadata.json') `
    -Content ($metadata | ConvertTo-Json -Depth 8)

# --------------------------------------------------------------------------
# README.md
# --------------------------------------------------------------------------

$peRow = if ($hasPrivateEndpoint) { "``$PrivateEndpointGroupId`` -> ``$PrivateDnsZone``" } else { 'none' }

$readme = @"
# $Name

$Description

| | |
|---|---|
| Kind | ``$Kind`` |
| Profiles | $(($Profiles | Sort-Object -Unique | ForEach-Object { "``$_``" }) -join ', ') |
| Abbreviation | ``$Abbreviation`` |
| Providers | $(($Provider | Sort-Object -Unique | ForEach-Object { "``$_``" }) -join ', ') |
| Private endpoint | $peRow |
| Feature flag | ``$zoneKey`` |
| Name rule | ``$NameRule`` |

## Purpose

TODO: describe what this module is for and when a project should opt into it.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| ``name`` | string | yes | |
| ``location`` | string | no | Defaults to the resource group location |
| ``tags`` | object | no | |$(if ($hasPrivateEndpoint) {
"
| ``privateEndpointSubnetId`` | string | no | Empty means public with firewall |
| ``privateDnsZoneId`` | string | no | Empty means public with firewall |" })

## Outputs

| Name | Notes |
|---|---|
| ``id`` | Contract output |
| ``name`` | Contract output |

## Wire-up

Generated by ``./scripts/add-module.ps1 -Module $Name``:

``````bicep
module $symbol './modules/$Name/main.bicep' = if (deploy$($symbol.Substring(0,1).ToUpperInvariant())$($symbol.Substring(1))) {
  name: '$Name'
  scope: resourceGroup
  params: {
    name: $($symbol)Name
    location: location
    tags: tags
  }
}
``````
"@

Write-ModuleFile -Path (Join-Path $moduleDir 'README.md') -Content $readme

# --------------------------------------------------------------------------
# Test stub
# --------------------------------------------------------------------------

$testPath = Join-Path $repoRoot "tests/modules/$Name.tests.ps1"
if ($PSCmdlet.ShouldProcess((Split-Path -Parent $testPath), 'Create test folder')) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $testPath) -Force
}

$testStub = @"
# Module-specific assertions for '$Name'.
#
# The uniform contract (params, outputs, metadata schema, catalog sync, build
# and lint) is already covered by tests/catalog.tests.ps1 and tests/bicep.tests.ps1.
# Add assertions here only for behaviour unique to this module.

. (Join-Path `$PSScriptRoot '..' 'assert.ps1')
. (Join-Path `$PSScriptRoot '..' 'common.ps1')

Test-Case '$Name declares the resource properties it needs' {
    `$bicep = Get-Content -LiteralPath (Get-RepoPath 'infra/modules/$Name/main.bicep') -Raw
    Assert-NotMatch -Actual `$bicep -Pattern 'TODO' ``
        -Message 'The scaffolded placeholders must be replaced before the module ships.'
}
"@

Write-ModuleFile -Path $testPath -Content $testStub

# --------------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess('infra/modules/catalog.json', 'Regenerate')) {
    & (Join-Path $PSScriptRoot 'build-catalog.ps1')
}

[pscustomobject] @{
    Module    = $Name
    Path      = $moduleDir
    TestStub  = $testPath
    NextSteps = @(
        "Replace the TODO placeholders in infra/modules/$Name/main.bicep",
        "Document the module in infra/modules/$Name/README.md",
        "Explicitly wire '$zoneKey' into Bicep and preflight featureSettings with a false default; catalog membership never enables it",
        './scripts/build-docs.ps1',
        "Wire it in with ./scripts/add-module.ps1 -Module $Name",
        './tests/run-tests.ps1'
    )
}
