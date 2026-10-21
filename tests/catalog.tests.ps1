# Rules checking for the module catalog.
#
# These cases enforce the contract that lets one module body serve every
# profile and lets preflight, private DNS and the docs be derived from
# metadata instead of hand-maintained.

. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')

$modulesRoot = Get-RepoPath 'infra/modules'
$catalogPath = Join-Path $modulesRoot 'catalog.json'

$moduleDirs = @(Get-ChildItem -LiteralPath $modulesRoot -Directory | Sort-Object Name)
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

$requiredKeys = @(
    'name', 'displayName', 'description', 'kind', 'abbreviation', 'featureFlag',
    'profiles', 'providers', 'privateEndpoints', 'roles', 'nameRule', 'preflight'
)
$knownKinds = @('resource', 'composite')
$knownNameRules = @('regional', 'global', 'globalCompact', 'hostname', 'fixed')
$knownProfiles = @('core', 'private', 'full')

Test-Case 'every module folder carries the three contract files' {
    foreach ($dir in $moduleDirs) {
        foreach ($required in @('main.bicep', 'metadata.json', 'README.md')) {
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $dir.FullName $required) -PathType Leaf) `
                -Message "Module '$($dir.Name)' is missing '$required'."
        }
    }
}

Test-Case 'metadata.json satisfies the catalog schema' {
    foreach ($dir in $moduleDirs) {
        $metadata = Get-Content -LiteralPath (Join-Path $dir.FullName 'metadata.json') -Raw | ConvertFrom-Json
        $present = $metadata.PSObject.Properties.Name

        foreach ($key in $requiredKeys) {
            Assert-True -Condition ($present -contains $key) `
                -Message "Module '$($dir.Name)' metadata is missing the required key '$key'."
        }

        Assert-Equal -Actual $metadata.name -Expected $dir.Name `
            -Message "Module '$($dir.Name)' metadata name must match its folder."
        Assert-True -Condition ($knownKinds -contains $metadata.kind) `
            -Message "Module '$($dir.Name)' has unknown kind '$($metadata.kind)'."
        Assert-True -Condition ($knownNameRules -contains $metadata.nameRule) `
            -Message "Module '$($dir.Name)' has unknown nameRule '$($metadata.nameRule)'."

        # A null abbreviation is only defensible when the service dictates the
        # resource names, which is exactly what nameRule 'fixed' declares.
        if ([string]::IsNullOrWhiteSpace([string] $metadata.abbreviation)) {
            Assert-Equal -Actual $metadata.nameRule -Expected 'fixed' `
                -Message "Module '$($dir.Name)' omits an abbreviation, so its nameRule must be 'fixed'."
        }

        $profiles = @($metadata.profiles)
        Assert-True -Condition ($profiles.Count -gt 0) `
            -Message "Module '$($dir.Name)' declares no profiles."
        foreach ($profileName in $profiles) {
            Assert-True -Condition ($knownProfiles -contains $profileName) `
                -Message "Module '$($dir.Name)' declares unknown profile '$profileName'."
        }

        Assert-True -Condition ($metadata.preflight.PSObject.Properties.Name -contains 'checks') `
            -Message "Module '$($dir.Name)' preflight block is missing 'checks'."
        Assert-True -Condition ($metadata.preflight.PSObject.Properties.Name -contains 'requiresOperatorPrincipals') `
            -Message "Module '$($dir.Name)' preflight block is missing 'requiresOperatorPrincipals'."
    }
}

Test-Case 'abbreviations are unique across the catalog' {
    $seen = @{}
    foreach ($module in $catalog.modules) {
        $claimed = @([string] $module.abbreviation) + @($module.additionalAbbreviations | ForEach-Object { [string] $_ })
        foreach ($abbreviation in $claimed) {
            if ([string]::IsNullOrEmpty($abbreviation)) { continue }
            # A shared building block such as 'nic' may be claimed by several
            # composites, so only a clash on the primary abbreviation fails.
            if ($abbreviation -eq [string] $module.abbreviation) {
                Assert-True -Condition (-not $seen.ContainsKey($abbreviation)) `
                    -Message "Abbreviation '$abbreviation' is claimed by both '$($seen[$abbreviation])' and '$($module.name)'."
            }
            if (-not $seen.ContainsKey($abbreviation)) {
                $seen[$abbreviation] = $module.name
            }
        }
    }
}

Test-Case 'private DNS zone keys are unique across the catalog' {
    $seen = @{}
    foreach ($module in $catalog.modules) {
        foreach ($endpoint in @($module.privateEndpoints)) {
            $zoneKey = [string] $endpoint.zoneKey
            Assert-True -Condition (-not $seen.ContainsKey($zoneKey)) `
                -Message "Private DNS zone key '$zoneKey' is claimed by both '$($seen[$zoneKey])' and '$($module.name)'."
            $seen[$zoneKey] = $module.name
        }
    }
}

Test-Case 'catalog.json is in sync with the modules on disk' {
    & (Get-RepoPath 'scripts/build-catalog.ps1') -Check | Out-Null
}

Test-Case 'catalog.json lists exactly the module folders on disk' {
    $onDisk = @($moduleDirs | ForEach-Object { $_.Name }) -join ','
    $inCatalog = @($catalog.modules | ForEach-Object { $_.name } | Sort-Object) -join ','
    Assert-Equal -Actual $inCatalog -Expected $onDisk `
        -Message 'catalog.json and infra/modules/ disagree about which modules exist.'
}

Test-Case 'every module declares the required params' {
    foreach ($dir in $moduleDirs) {
        $bicep = Get-Content -LiteralPath (Join-Path $dir.FullName 'main.bicep') -Raw
        foreach ($param in @('location', 'tags')) {
            Assert-Match -Actual $bicep -Pattern "(?m)^param\s+$param\s" `
                -Message "Module '$($dir.Name)' does not declare the required param '$param'."
        }
    }
}

Test-Case 'resource modules declare a name param and the id and name outputs' {
    foreach ($module in $catalog.modules) {
        if ($module.kind -ne 'resource') { continue }

        $bicep = Get-Content -LiteralPath (Join-Path $modulesRoot "$($module.name)/main.bicep") -Raw
        Assert-Match -Actual $bicep -Pattern "(?m)^param\s+name\s" `
            -Message "Module '$($module.name)' does not declare the required param 'name'."
        foreach ($outputName in @('id', 'name')) {
            Assert-Match -Actual $bicep -Pattern "(?m)^output\s+$outputName\s+string\s*=" `
                -Message "Module '$($module.name)' does not declare the required output '$outputName'."
        }
    }
}

Test-Case 'modules with private endpoints accept a subnet and a DNS zone' {
    foreach ($module in $catalog.modules) {
        $endpoints = @($module.privateEndpoints)
        if ($endpoints.Count -eq 0) { continue }

        $bicep = Get-Content -LiteralPath (Join-Path $modulesRoot "$($module.name)/main.bicep") -Raw
        Assert-Match -Actual $bicep -Pattern "(?m)^param\s+privateEndpointSubnetId\s+string" `
            -Message "Module '$($module.name)' declares private endpoints but has no privateEndpointSubnetId param."
        Assert-Match -Actual $bicep -Pattern 'core/private-endpoint\.bicep' `
            -Message "Module '$($module.name)' declares private endpoints but does not use the shared core/private-endpoint.bicep pattern."
    }
}

Test-Case 'private endpoint modules stay public-capable, so one body serves every profile' {
    foreach ($module in $catalog.modules) {
        if (@($module.privateEndpoints).Count -eq 0) { continue }

        $bicep = Get-Content -LiteralPath (Join-Path $modulesRoot "$($module.name)/main.bicep") -Raw
        Assert-Match -Actual $bicep -Pattern 'empty\(privateEndpointSubnetId\)' `
            -Message "Module '$($module.name)' must branch on an empty privateEndpointSubnetId so the core profile can deploy it without a network."
    }
}

Test-Case 'generated private DNS zone catalog matches module metadata' {
    $zones = Get-Content -LiteralPath (Get-RepoPath 'infra/core/private-dns-zones.json') -Raw | ConvertFrom-Json

    $expected = [System.Collections.Generic.List[string]]::new()
    foreach ($module in $catalog.modules) {
        foreach ($endpoint in @($module.privateEndpoints)) {
            $expected.Add("$($endpoint.zoneKey)=$($endpoint.dnsZone)")
        }
    }

    $actual = @($zones | ForEach-Object { "$($_.key)=$($_.zone)" })
    Assert-Equal -Actual (($actual | Sort-Object) -join ',') -Expected (($expected.ToArray() | Sort-Object) -join ',') `
        -Message 'infra/core/private-dns-zones.json does not match the private endpoints declared in module metadata.'
}

Test-Case 'private DNS virtual network link names are preserved' {
    # These names are on deployed resources. Changing the derivation replaces them.
    $zones = Get-Content -LiteralPath (Get-RepoPath 'infra/core/private-dns-zones.json') -Raw | ConvertFrom-Json
    $expected = @{
        keyVault = 'kv'
        blob     = 'blob'
        file     = 'file'
    }

    foreach ($entry in $zones) {
        if (-not $expected.ContainsKey($entry.key)) { continue }
        Assert-Equal -Actual $entry.linkSuffix -Expected $expected[$entry.key] `
            -Message "Private DNS link suffix for zone '$($entry.key)' changed, which renames a deployed virtual network link."
    }
}

Test-Case 'preflight selects catalog modules through metadata without implicitly enabling additions' {
    . (Get-RepoPath 'scripts/module-selection.ps1')
    $preflight = Get-Content -LiteralPath (Get-RepoPath 'scripts/preflight.ps1') -Raw
    Assert-True -Condition $preflight.Contains('Get-EnabledCatalogModules -Modules $catalog.modules') -Message 'Preflight must use catalog selection.'
    $modules = @(
        @{ name = 'new-enabled'; featureFlag = 'approvedFeature'; providers = @('Microsoft.Example') }
        @{ name = 'new-disabled'; featureFlag = 'disabledFeature' }
        @{ name = 'new-unknown'; featureFlag = 'unwiredFeature' }
        @{ name = 'new-unconditional'; featureFlag = $null }
    )
    $enabled = @(Get-EnabledCatalogModules -Modules $modules -Features @{ approvedFeature = $true; disabledFeature = $false } -Composition @{})
    Assert-Equal -Actual $enabled.Count -Expected 1 -Message 'Only explicitly enabled known features may be selected.'
    Assert-Equal -Actual $enabled[0].name -Expected 'new-enabled' -Message 'New module names must not require hardcoding.'
    Assert-Equal -Actual $enabled[0].providers[0] -Expected 'Microsoft.Example' -Message 'Provider metadata must survive selection.'
}

Test-Case 'every declared provider is a Microsoft resource provider namespace' {
    foreach ($module in $catalog.modules) {
        foreach ($provider in @($module.providers)) {
            Assert-Match -Actual $provider -Pattern '^Microsoft\.[A-Za-z]+$' `
                -Message "Module '$($module.name)' declares a malformed provider '$provider'."
        }
    }
}

Test-Case 'module abbreviations resolve through infra/core/abbreviations.json' {
    $abbreviations = Get-Content -LiteralPath (Get-RepoPath 'infra/core/abbreviations.json') -Raw | ConvertFrom-Json
    $values = @($abbreviations.PSObject.Properties | ForEach-Object { $_.Value })

    foreach ($module in $catalog.modules) {
        $claimed = @([string] $module.abbreviation) + @($module.additionalAbbreviations | ForEach-Object { [string] $_ })
        foreach ($abbreviation in $claimed) {
            if ([string]::IsNullOrEmpty($abbreviation)) { continue }
            Assert-True -Condition ($values -contains $abbreviation) `
                -Message "Abbreviation '$abbreviation' for module '$($module.name)' is not in infra/core/abbreviations.json."
        }
    }
}

Test-Case 'the generated sections of docs/modules.md are in sync with the catalog' {
    # The module table is derived from metadata, so a new module documents
    # itself. This asserts nobody hand-edited it back out of sync.
    & (Get-RepoPath 'scripts/build-docs.ps1') -Check | Out-Null
}