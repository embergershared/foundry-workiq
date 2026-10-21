# Naming rules and the zero-drift proof.
#
# The refactor moved the resource-name algorithm out of infra/main.bicep and into
# infra/core/naming.bicep. An environment is already deployed from the previous
# algorithm, and a changed name means a replaced resource, so the equivalence
# below is the gate on the whole refactor.
#
# The proof has two independent legs:
#   1. tests/fixtures/legacy-naming.ps1 is a frozen transcription of the
#      pre-refactor algorithm. Its output is committed as legacy-names.golden.json.
#   2. The *compiled* ARM of infra/main.bicep is evaluated offline and compared
#      to that golden file, name by name.
# Leg 2 is what makes the proof binding: it exercises the Bicep the deployment
# actually uses, not a PowerShell restatement of it.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'arm-expression.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'fixtures\legacy-naming.ps1')
. (Join-Path (Get-RepoRoot) 'scripts\naming.ps1')

$abbreviationsPath = Get-RepoPath 'infra\core\abbreviations.json'
$locationCodesPath = Get-RepoPath 'infra\core\location-codes.json'
$nameRulesPath = Get-RepoPath 'infra\core\name-rules.json'
$tenantCodesPath = Get-RepoPath 'infra\core\tenant-codes.json'
$tenantCodesExamplePath = Get-RepoPath 'infra\core\tenant-codes.example.json'
$goldenPath = Get-RepoPath 'tests\fixtures\legacy-names.golden.json'

$abbreviations = Get-Content -LiteralPath $abbreviationsPath -Raw | ConvertFrom-Json -AsHashtable
$locationCodes = Get-Content -LiteralPath $locationCodesPath -Raw | ConvertFrom-Json -AsHashtable
$nameRules = Get-Content -LiteralPath $nameRulesPath -Raw | ConvertFrom-Json -AsHashtable
$tenantCodes = Get-Content -LiteralPath $tenantCodesPath -Raw | ConvertFrom-Json -AsHashtable
$golden = Get-Content -LiteralPath $goldenPath -Raw | ConvertFrom-Json -AsHashtable
$matrix = Get-LegacyNameMatrix

Test-Case 'golden name file still matches the frozen legacy algorithm' {
    Assert-Equal $golden.Count $matrix.Count 'Golden row count drifted from the input matrix.'

    for ($i = 0; $i -lt $matrix.Count; $i++) {
        $case = $matrix[$i]
        $row = $golden[$i]

        Assert-Equal $row.environmentName $case.EnvironmentName "Row $i environment name drifted."
        Assert-Equal $row.subscriptionCode $case.SubscriptionCode "Row $i subscription code drifted."
        Assert-Equal $row.locationCode $case.LocationCode "Row $i location code drifted."

        $expected = Get-LegacyNames -Abbreviations $abbreviations `
            -LocationCode $case.LocationCode -SubscriptionCode $case.SubscriptionCode `
            -EnvironmentName $case.EnvironmentName -ShortUniqueSuffix $case.ShortUniqueSuffix

        foreach ($key in $expected.Keys) {
            Assert-Equal ([string] $row.names[$key]) ([string] $expected[$key]) `
                "Row $i golden name '$key' no longer matches the frozen algorithm."
        }
    }
}

Test-Case 'compiled infra/main.bicep reproduces every pre-refactor resource name' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra\main.bicep')
    $map = Get-NameVariableMap

    $firstRow = $golden[0]
    foreach ($key in $firstRow.names.Keys) {
        Assert-True $map.ContainsKey($key) `
            "The frozen fixture produces '$key' but no infra/main.bicep variable is mapped to it."
    }

    for ($i = 0; $i -lt $matrix.Count; $i++) {
        $case = $matrix[$i]
        $rendered = Get-BicepRenderedNames -Template $template `
            -LocationCode $case.LocationCode -SubscriptionCode $case.SubscriptionCode `
            -EnvironmentName $case.EnvironmentName -ShortUniqueSuffix $case.ShortUniqueSuffix

        foreach ($key in $golden[$i].names.Keys) {
            Assert-Equal $rendered[$key] ([string] $golden[$i].names[$key]) `
                ("Resource name drift for '$key' at environment '$($case.EnvironmentName)', " +
                "subscription '$($case.SubscriptionCode)', location '$($case.LocationCode)'. " +
                'Deploying this would REPLACE the existing resource.')
        }
    }
}

Test-Case 'a tenant with an empty code keeps the pre-tenant my-azd-env-test names' {
    # Pinning one environment explicitly makes a regression name the affected
    # environment instead of a matrix index.
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra\main.bicep')
    $rendered = Get-BicepRenderedNames -Template $template -LocationCode 'use2' `
        -SubscriptionCode 's1' -EnvironmentName 'my-azd-env-test' -ShortUniqueSuffix 'abc'
    $expected = Get-LegacyNames -Abbreviations $abbreviations -LocationCode 'use2' `
        -SubscriptionCode 's1' -EnvironmentName 'my-azd-env-test' -ShortUniqueSuffix 'abc'

    foreach ($key in $expected.Keys) {
        Assert-Equal $rendered[$key] ([string] $expected[$key]) "my-azd-env-test '$key' drifted."
    }
}

Test-Case 'every rendered name satisfies infra/core/name-rules.json' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra\main.bicep')

    # The empty code covers pre-tenant names; twelve characters is the longest code allowed.
    foreach ($case in $matrix) {
      foreach ($tenantCode in @('', ('9' * 12))) {
        $rendered = Get-BicepRenderedNames -Template $template `
            -LocationCode $case.LocationCode -SubscriptionCode $case.SubscriptionCode `
            -EnvironmentName $case.EnvironmentName -ShortUniqueSuffix $case.ShortUniqueSuffix `
            -TenantCode $tenantCode

        foreach ($key in $rendered.Keys) {
            Assert-True $nameRules.resources.ContainsKey($key) `
                "infra/core/name-rules.json has no rule for '$key'."
            $rule = $nameRules.resources[$key]
            $name = [string] $rendered[$key]
            $minLength = if ($rule.ContainsKey('minLength')) { [int] $rule.minLength } else { 1 }

            Assert-True ($name.Length -le $rule.maxLength) `
                "'$key' name '$name' is $($name.Length) characters, over the $($rule.maxLength) limit."
            Assert-True ($name.Length -ge $minLength) `
                "'$key' name '$name' is shorter than the $minLength character minimum."
            Assert-Match $name $rule.charset "'$key' violates its charset rule."
            if ($rule.case -eq 'lower') {
                Assert-Equal $name $name.ToLowerInvariant() "'$key' name must be lowercase."
            }
            Assert-True $nameRules.classes.ContainsKey($rule.class) `
                "'$key' references the undefined name class '$($rule.class)'."
        }
      }
    }
}

Test-Case 'a tenant code is inserted into regional names only' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra\main.bicep')

    for ($i = 0; $i -lt $matrix.Count; $i++) {
        $case = $matrix[$i]
        $rendered = Get-BicepRenderedNames -Template $template `
            -LocationCode $case.LocationCode -SubscriptionCode $case.SubscriptionCode `
            -EnvironmentName $case.EnvironmentName -ShortUniqueSuffix $case.ShortUniqueSuffix `
            -TenantCode '123456'
        $body = "-$($case.LocationCode)-$($case.SubscriptionCode)-"

        foreach ($key in $golden[$i].names.Keys) {
            $old = [string] $golden[$i].names[$key]
            $at = $old.IndexOf($body)
            $expected = if ($nameRules.resources[$key].class -eq 'regional') {
                $old.Substring(0, $at) + "-123456" + $old.Substring($at)
            }
            else { $old }
            Assert-Equal $rendered[$key] $expected "'$key' did not place the tenant code correctly."
        }
    }

    $bicepGroup = (Get-BicepRenderedNames -Template $template -LocationCode 'use2' -SubscriptionCode 's2' `
            -EnvironmentName 'my-azd-env-test' -ShortUniqueSuffix 'abc' -TenantCode '123456').resourceGroup
    Assert-Equal $bicepGroup 'rg-123456-use2-s2-my-azd-env-test' 'Tenant-coded resource group name mismatch.'
    Assert-Equal (Get-AzName -Abbreviation 'rg' -TenantCode '123456' -LocationCode 'use2' `
            -SubscriptionCode 's2' -EnvironmentName 'my-azd-env-test') $bicepGroup `
        'Get-AzName differs from the Bicep azName for a tenant code.'
}

Test-Case 'the tenant-code catalog is valid and agrees with Bicep tenantCodeFor' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra\main.bicep')

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $tenantCodes.GetEnumerator()) {
        $tenantId = [string] $entry.Key
        $parsed = [Guid]::Empty
        Assert-True ([Guid]::TryParseExact($tenantId, 'D', [ref] $parsed)) "Tenant key '$tenantId' is not a GUID."
        Assert-Equal $tenantId $tenantId.ToLowerInvariant() 'Tenant keys must be lowercase.'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string] $entry.Value.name)) "Tenant '$tenantId' has no name."

        $fromScript = Get-TenantCode -TenantId $tenantId.ToUpperInvariant() -CatalogPath $tenantCodesPath
        $fromBicep = [string] (Invoke-ArmExpression -Expression "[__bicep.tenantCodeFor('$($tenantId.ToUpperInvariant())')]" `
                -Template $template)
        Assert-Equal $fromBicep $fromScript "Tenant code for '$tenantId' differs between PowerShell and Bicep."
        if ($fromScript) { Assert-True ($seen.Add($fromScript)) "Tenant code '$fromScript' is duplicated." }
    }

    Assert-Throws { Get-TenantCode -TenantId 'ffffffff-ffff-ffff-ffff-ffffffffffff' -CatalogPath $tenantCodesPath } `
        'Unknown tenants must fail.'
}

Test-Case 'the example tenant-code catalog is what a new repository starts from' {
    # The real catalog holds the template owner's tenants; a repository created
    # from the template replaces it with this file (scripts/init-from-template.ps1).
    Assert-Equal (Get-TenantCode -TenantId '00000000-0000-0000-0000-000000000000' -CatalogPath $tenantCodesExamplePath) '123456' `
        'Example tenant code mismatch.'
    Assert-Throws { Get-TenantCode -TenantId 'ffffffff-ffff-ffff-ffff-ffffffffffff' -CatalogPath $tenantCodesExamplePath } `
        'Unknown tenants must fail against the example catalog.'
}

Test-Case 'globally unique names keep prefix, location, subscription and hash' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra\main.bicep')

    foreach ($case in $matrix) {
        $rendered = Get-BicepRenderedNames -Template $template `
            -LocationCode $case.LocationCode -SubscriptionCode $case.SubscriptionCode `
            -EnvironmentName $case.EnvironmentName -ShortUniqueSuffix $case.ShortUniqueSuffix

        $hash = $case.ShortUniqueSuffix
        Assert-Match $rendered.keyVault "^$($abbreviations.keyVault)-$($case.LocationCode)-$($case.SubscriptionCode)-.+-$hash$" `
            'Key Vault name lost a mandatory segment.'
        Assert-Match $rendered.storageAccount "^$($abbreviations.storageAccount)$($case.LocationCode)$($case.SubscriptionCode).+$hash$" `
            'Storage account name lost a mandatory segment.'
        Assert-Match $rendered.windowsComputerName "^w-.+-$hash$" `
            'Windows computer name lost a mandatory segment.'
    }
}

Test-Case 'platform-managed resource groups are the owning resource group name plus -managed' {
    $namingBicep = Get-Content -LiteralPath (Get-RepoPath 'infra/core/naming.bicep') -Raw
    Assert-True ($namingBicep -cmatch "func managedResourceGroupName\(resourceGroupName string\) string => '\$\{resourceGroupName\}-managed'") `
        'naming.bicep managedResourceGroupName must stay <resource group name>-managed.'

    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/main.bicep')
    $rule = $nameRules.resources['managedResourceGroup']
    foreach ($case in $matrix) {
        $rendered = Get-BicepRenderedNames -Template $template `
            -LocationCode $case.LocationCode -SubscriptionCode $case.SubscriptionCode `
            -EnvironmentName $case.EnvironmentName -ShortUniqueSuffix $case.ShortUniqueSuffix
        $managed = Get-ManagedResourceGroupName -ResourceGroupName $rendered.resourceGroup

        Assert-Equal $managed "$($rendered.resourceGroup)-managed" 'Managed resource group name drifted.'
        Assert-True ($managed.Length -le $rule.maxLength) `
            "Managed resource group name '$managed' exceeds $($rule.maxLength) characters."
        Assert-Match $managed $rule.charset "Managed resource group name '$managed' breaks the charset rule."
    }
}

Test-Case 'AzureBastionSubnet keeps its Azure-mandated name' {
    Assert-True $nameRules.reserved.ContainsKey('AzureBastionSubnet') `
        'The reserved Bastion subnet name must stay exactly AzureBastionSubnet.'

    $networkBicep = Get-Content -LiteralPath (Get-RepoPath 'infra\modules\network\main.bicep') -Raw
    Assert-True ($networkBicep -cmatch "'AzureBastionSubnet'") `
        'The network module must still hard-code AzureBastionSubnet.'
}

Test-Case 'the location-code catalog is complete and unambiguous' {
    Assert-True ($locationCodes.Count -ge 50) `
        "The public-cloud location catalog unexpectedly contains only $($locationCodes.Count) entries."

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $locationCodes.GetEnumerator()) {
        Assert-Match ([string] $entry.Key) '^[a-z0-9]+$' 'Location key is not canonical lowercase alphanumeric.'
        Assert-Match ([string] $entry.Value) '^[a-z]{2}[a-z0-9]{0,3}$' "Location '$($entry.Key)' has an invalid code."
        Assert-True ($seen.Add([string] $entry.Value)) "Location code '$($entry.Value)' is duplicated."
    }
}

Test-Case 'Get-LocationCode agrees with the Bicep locationCodeFor function' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra\main.bicep')

    foreach ($location in @('eastus2', 'westus3', 'canadacentral')) {
        $fromScript = Get-LocationCode -Location $location -CatalogPath $locationCodesPath
        $fromBicep = [string] (Invoke-ArmExpression -Expression $template.variables.locationCode `
                -Template $template -Parameters @{ location = $location })
        Assert-Equal $fromBicep $fromScript "Location code for '$location' differs between PowerShell and Bicep."
    }

    Assert-Throws { Get-LocationCode -Location 'moonbase1' -CatalogPath $locationCodesPath } `
        'Unknown locations must fail.'
}

Test-Case 'subscription codes derive and remain stable' {
    Assert-Equal (Get-SubscriptionCode -SubscriptionName 'Contoso-Dev-1') 's1' 'One-digit subscription code mismatch.'
    Assert-Equal (Get-SubscriptionCode -SubscriptionName 'example-1234') 's1234' 'Four-digit subscription code mismatch.'
    Assert-Equal (Get-SubscriptionCode -SubscriptionName 'Contoso-s2-Sandbox') 's2' 'Delimited s<N> token mismatch.'
    Assert-Equal (Get-SubscriptionCode -SubscriptionName 'Fabrikam-123456-s1') 's1' 'Final s<N> token mismatch.'
    Assert-Equal (Get-SubscriptionCode -SubscriptionName 'Contoso_S12 Projects') 's12' 's<N> token delimiters mismatch.'
    Assert-Equal (Get-SubscriptionCode -SubscriptionName 'Demo-s2-Projects-3') 's3' 'Numeric suffix must win over an s<N> token.'
    Assert-Throws { Get-SubscriptionCode -SubscriptionName 'Projects2-Dev' } 'Undelimited token must not derive a code.'
    Assert-Equal (Get-SubscriptionCode -SubscriptionName 'example' -SubscriptionId 'abcd1234-0000-4000-8000-000000000000') 'sabcd' `
        'Subscription ID fallback mismatch.'
    Assert-Throws { Get-SubscriptionCode -SubscriptionName 'example' } 'Missing subscription token must fail.'
    Assert-Throws { Get-SubscriptionCode -SubscriptionName 'example-final' } 'Nonnumeric subscription token must fail.'
    Assert-Throws { Get-SubscriptionCode -SubscriptionName 'example-12345' } 'Five-digit subscription token must fail.'
    Assert-Equal (Assert-SubscriptionCode -SubscriptionName 'example-3' -CachedCode 's3') 's3' 'Cached subscription code mismatch.'
    Assert-Throws { Assert-SubscriptionCode -SubscriptionName 'example-3' -CachedCode 's1' } 'Subscription code drift must fail.'
    Assert-Equal (Assert-SubscriptionCode -SubscriptionName 'Contoso-s2-Sandbox' -CachedCode 's2') 's2' 's<N> cached code mismatch.'
    Assert-Throws { Assert-SubscriptionCode -SubscriptionName 'Contoso-s2-Sandbox' -CachedCode 's1' } 's<N> code drift must fail.'
    Assert-Equal (Assert-SubscriptionCode -SubscriptionName 'Contoso Projects' -CachedCode 's7') 's7' `
        'Explicit code must be accepted for a name without a code.'
}
