# Shared helpers for the tests/ suite: repository paths, a cached compiled ARM
# template, and the fixed input matrix used by the naming proofs.

Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:CompiledTemplates = @{}
$script:LocationByCode = $null

function Get-RepoRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:RepoRoot
}

function Get-RepoPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    return (Join-Path $script:RepoRoot $RelativePath)
}

function Get-CompiledTemplate {
    <#
    .SYNOPSIS
        Compiles a Bicep file to ARM JSON and caches the result for the run.
    .DESCRIPTION
        Compilation is the slowest part of the suite, so each file is built at
        most once even though several test cases consume it.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string] $BicepPath
    )

    $full = (Resolve-Path $BicepPath).Path
    if ($script:CompiledTemplates.ContainsKey($full)) {
        return $script:CompiledTemplates[$full]
    }

    $diagnostics = Join-Path $script:RepoRoot ('.bicep-diagnostics-' + [guid]::NewGuid().ToString('N'))
    try {
        $json = az bicep build --file $full --stdout 2> $diagnostics
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $diagnostics) { [IO.File]::ReadAllText($diagnostics) } else { '' }
        if ($exitCode -ne 0) {
            throw "az bicep build failed for '$full' (exit $exitCode):`n$stderr`n$($json -join [Environment]::NewLine)"
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Warning $stderr.Trim() }
    }
    finally {
        if (Test-Path -LiteralPath $diagnostics) { Remove-Item -LiteralPath $diagnostics -Force }
    }

    $template = ($json -join [Environment]::NewLine) | ConvertFrom-Json
    $script:CompiledTemplates[$full] = $template
    return $template
}

function Get-LocationForCode {
    <#
    .SYNOPSIS
        Reverses the location-code catalog so a test can drive main.bicep, which
        takes a region and derives the code, from a fixed code.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Code
    )

    if (-not $script:LocationByCode) {
        $catalog = Get-Content -LiteralPath (Get-RepoPath 'infra\core\location-codes.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $script:LocationByCode = @{}
        foreach ($entry in $catalog.GetEnumerator()) {
            $script:LocationByCode[[string] $entry.Value] = [string] $entry.Key
        }
    }

    if (-not $script:LocationByCode.ContainsKey($Code)) {
        throw "No Azure region maps to location code '$Code'."
    }
    return $script:LocationByCode[$Code]
}

# Maps the frozen fixture's logical name keys onto the variable names emitted by
# infra/main.bicep. Every legacy key must appear here; the equivalence test
# asserts the mapping covers the whole fixture.
function Get-NameVariableMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        resourceGroup              = 'resourceGroupName'
        virtualNetwork             = 'vnetName'
        bastionNsg                 = 'bastionNsgName'
        jumpboxNsg                 = 'jumpboxNsgName'
        privateEndpointNsg         = 'privateEndpointNsgName'
        jumpboxSubnet              = 'jumpboxSubnetName'
        privateEndpointSubnet      = 'privateEndpointSubnetName'
        keyVault                   = 'keyVaultName'
        keyVaultPrivateEndpoint    = 'keyVaultPrivateEndpointName'
        keyVaultPrivateEndpointNic = 'keyVaultPrivateEndpointNicName'
        storageAccount             = 'storageAccountName'
        blobPrivateEndpoint        = 'blobPrivateEndpointName'
        blobPrivateEndpointNic     = 'blobPrivateEndpointNicName'
        filePrivateEndpoint        = 'filePrivateEndpointName'
        filePrivateEndpointNic     = 'filePrivateEndpointNicName'
        logAnalytics               = 'logAnalyticsName'
        applicationInsights        = 'appInsightsName'
        natGateway                 = 'natGatewayName'
        natPublicIp                = 'natGatewayPublicIpName'
        bastion                    = 'bastionName'
        bastionPublicIp            = 'bastionPublicIpName'
        windowsVm                  = 'windowsVmName'
        windowsComputerName        = 'windowsComputerName'
        windowsNic                 = 'windowsNicName'
        linuxVm                    = 'linuxVmName'
        linuxNic                   = 'linuxNicName'
    }
}

function Get-ProfileFeatureFlags {
    <#
    .SYNOPSIS
        Evaluates the deployment feature flags that infra/main.bicep derives for
        one profile, entirely offline, from the compiled ARM template.
    .DESCRIPTION
        This is what turns the three-rung ladder from a documented intention
        into a tested one: the flags come out of the same `coalesce`/`union`
        expressions the deployment evaluates, not out of a mirror in the test.
    .PARAMETER Overrides
        Feature-override object, exactly as AZURE_FEATURE_OVERRIDES_JSON carries
        it. Encoded here so the expert-override path is covered too.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [psobject] $Template,
        [Parameter(Mandatory)] [string] $ProfileName,
        [hashtable] $Overrides = @{},
        [bool] $EnableRoleAssignments = $true
    )

    $json = if ($Overrides.Count -eq 0) { '{}' } else { $Overrides | ConvertTo-Json -Depth 4 -Compress }
    $parameters = @{
        deploymentProfile       = $ProfileName
        enableNetwork           = $null
        enableKeyVault          = $null
        enableStorage           = $null
        enableBastion           = $null
        enableWindowsVm         = $null
        enableLinuxVm           = $null
        enableNatGateway        = $null
        enableEntraLogin        = $null
        enableShutdownSchedules = $null
        enableRoleAssignments   = $EnableRoleAssignments
        featureOverridesBase64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    }

    $flags = @{}
    foreach ($name in @(
            'deployNetwork', 'deployKeyVault', 'deployStorage', 'deployBastion',
            'deployWindowsVm', 'deployLinuxVm', 'deployNatGateway', 'deployEntraLogin',
            'deployShutdownSchedules', 'deployAnyVm', 'assignRoles')) {
        $expression = $Template.variables.$name
        if ($null -eq $expression) {
            throw "infra/main.bicep no longer defines the variable '$name'."
        }
        $flags[$name] = [bool] (Invoke-ArmExpression -Expression $expression `
                -Template $Template -Parameters $parameters)
    }
    $flags['resolvedProfile'] = [string] (Invoke-ArmExpression -Expression $Template.variables.resolvedProfile `
            -Template $Template -Parameters $parameters)
    return $flags
}

function Get-EnabledDeployments {
    <#
    .SYNOPSIS
        Returns the symbolic names of the module deployments that survive the
        condition evaluation for one profile.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [psobject] $Template,
        [Parameter(Mandatory)] [hashtable] $Flags
    )

    $variables = @{}
    foreach ($pair in $Flags.GetEnumerator()) { $variables[$pair.Key] = $pair.Value }

    $enabled = @()
    foreach ($property in $Template.resources.PSObject.Properties) {
        $resource = $property.Value
        if ($resource.type -ne 'Microsoft.Resources/deployments') { continue }
        if (-not $resource.PSObject.Properties['condition']) {
            $enabled += $property.Name
            continue
        }
        $keep = [bool] (Invoke-ArmExpression -Expression $resource.condition `
                -Template $Template -Variables $variables)
        if ($keep) { $enabled += $property.Name }
    }
    return [string[]] $enabled
}

function Get-BicepRenderedNames {
    <#
    .SYNOPSIS
        Evaluates every resource-name variable in the compiled infra/main.bicep
        for one set of inputs, entirely offline.
    .DESCRIPTION
        `shortUniqueSuffix` wraps uniqueString(subscription().id, ...) and
        `tenantCode` wraps tenant().tenantId; neither has an offline value, so
        both are pinned through the Variables override. An empty TenantCode
        renders the pre-tenant names the legacy proof compares against.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [psobject] $Template,
        [Parameter(Mandatory)] [string] $LocationCode,
        [Parameter(Mandatory)] [string] $SubscriptionCode,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [string] $ShortUniqueSuffix,

        [AllowEmptyString()]
        [string] $TenantCode = ''
    )

    $parameters = @{
        location         = Get-LocationForCode -Code $LocationCode
        subscriptionCode = $SubscriptionCode
        environmentName  = $EnvironmentName
    }
    $variables = @{ shortUniqueSuffix = $ShortUniqueSuffix; tenantCode = $TenantCode }

    $rendered = @{}
    foreach ($pair in (Get-NameVariableMap).GetEnumerator()) {
        $expression = $Template.variables.($pair.Value)
        if ($null -eq $expression) {
            throw "infra/main.bicep no longer defines the variable '$($pair.Value)'."
        }
        $rendered[$pair.Key] = [string] (Invoke-ArmExpression -Expression $expression `
                -Template $Template -Parameters $parameters -Variables $variables)
    }
    return $rendered
}
