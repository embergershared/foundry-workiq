# Compilation, lint and profile-ladder proofs.
#
# The naming suite proves names do not drift. This suite proves the template
# still compiles cleanly and that the three-rung ladder actually gates what it
# claims to gate -- evaluated from the emitted ARM, not from a mirror of the
# rules written in PowerShell.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'arm-expression.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')

$mainBicep = Get-RepoPath 'infra/main.bicep'
$catalog = Get-Content -LiteralPath (Get-RepoPath 'infra/modules/catalog.json') -Raw | ConvertFrom-Json
$template = Get-CompiledTemplate -BicepPath $mainBicep

# Symbolic deployment name in main.bicep -> catalog module name. Kept explicit
# because a module may be invoked under a different symbol than its folder.
$deploymentToModule = @{
    monitoring = 'monitoring'
    natGateway = 'nat-gateway'
    network    = 'network'
    privateDns = 'private-dns'
    keyVault   = 'key-vault'
    storage    = 'storage'
    bastion    = 'bastion'
    jumpboxes  = 'jumpboxes'
}

function Get-BicepFilesUnderTest {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $files = @($mainBicep)
    $files += @(Get-ChildItem -LiteralPath (Get-RepoPath 'infra/core') -Filter '*.bicep' -File |
            ForEach-Object { $_.FullName })
    $files += @($catalog.modules | ForEach-Object { Get-RepoPath $_.path })
    return [string[]] $files
}

function Invoke-Bicep {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateSet('build', 'lint')] [string] $Command,
        [Parameter(Mandatory)] [string] $Path
    )

    $arguments = @('bicep', $Command, '--file', $Path)
    if ($Command -eq 'build') { $arguments += '--stdout' }

    $output = & az @arguments 2>&1
    return @{
        ExitCode = $LASTEXITCODE
        Output   = ($output | ForEach-Object { [string] $_ }) -join [Environment]::NewLine
    }
}

function Get-TemplateResourceList {
    <#
    .SYNOPSIS
        Normalises a template's `resources` into a flat list, tolerating both
        the array form and the symbolic-name object form of languageVersion 2.0.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Resources
    )

    if ($null -eq $Resources) { return @() }
    if ($Resources -is [System.Collections.IEnumerable] -and $Resources -isnot [string] -and
        $Resources -isnot [psobject]) {
        return [psobject[]] @($Resources)
    }
    if ($Resources -is [array]) { return [psobject[]] $Resources }
    return [psobject[]] @($Resources.PSObject.Properties | ForEach-Object { $_.Value })
}

function Get-NestedResourceTypes {
    <#
    .SYNOPSIS
        Collects every resource type a deployment would create, following nested
        templates all the way down.
    .DESCRIPTION
        Conditions inside a nested template are deliberately ignored. The claim
        under test is the stronger one: under the core profile no enabled module
        contains a networking or compute resource at all, so no condition has to
        be trusted to keep one out.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Resource
    )

    if ($null -eq $Resource) { return @() }

    $types = @()
    $resourceType = [string] $Resource.type

    if ($resourceType -eq 'Microsoft.Resources/deployments') {
        $nested = $Resource.properties.template
        if ($null -ne $nested -and $nested.PSObject.Properties['resources']) {
            foreach ($child in (Get-TemplateResourceList -Resources $nested.resources)) {
                $types += Get-NestedResourceTypes -Resource $child
            }
        }
        return [string[]] $types
    }

    # An `existing` reference reads a resource; it never creates one.
    if ($Resource.PSObject.Properties['existing'] -and $Resource.existing) { return [string[]] @() }

    $types += $resourceType
    if ($Resource.PSObject.Properties['resources']) {
        foreach ($child in (Get-TemplateResourceList -Resources $Resource.resources)) {
            $types += Get-NestedResourceTypes -Resource $child
        }
    }
    return [string[]] $types
}

function Get-ResourceTypesForProfile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $ProfileName
    )

    $flags = Get-ProfileFeatureFlags -Template $template -ProfileName $ProfileName
    $enabled = Get-EnabledDeployments -Template $template -Flags $flags

    $types = @()
    foreach ($property in $template.resources.PSObject.Properties) {
        $resource = $property.Value
        if ($resource.type -eq 'Microsoft.Resources/deployments' -and $enabled -notcontains $property.Name) {
            continue
        }
        $types += Get-NestedResourceTypes -Resource $resource
    }
    return [string[]] ($types | Sort-Object -Unique)
}

Test-Case 'every Bicep file in the template compiles' {
    foreach ($file in (Get-BicepFilesUnderTest)) {
        $result = Invoke-Bicep -Command build -Path $file
        Assert-Equal -Actual $result.ExitCode -Expected 0 `
            -Message "az bicep build failed for '$file':`n$($result.Output)"
    }
}

Test-Case 'every Bicep file in the template lints clean' {
    foreach ($file in (Get-BicepFilesUnderTest)) {
        $result = Invoke-Bicep -Command lint -Path $file
        Assert-Equal -Actual $result.ExitCode -Expected 0 `
            -Message "az bicep lint failed for '$file':`n$($result.Output)"
        Assert-NotMatch -Actual $result.Output -Pattern '\b(Warning|Error)\b' `
            -Message "az bicep lint reported a diagnostic for '$file':`n$($result.Output)"
    }
}

Test-Case 'the core profile deploys no networking and no compute' {
    $flags = Get-ProfileFeatureFlags -Template $template -ProfileName 'core'

    foreach ($flag in @('deployNetwork', 'deployKeyVault', 'deployStorage', 'deployBastion',
            'deployWindowsVm', 'deployLinuxVm', 'deployNatGateway', 'deployEntraLogin',
            'deployShutdownSchedules', 'deployAnyVm')) {
        Assert-Equal -Actual $flags[$flag] -Expected $false `
            -Message "The core profile must leave '$flag' off."
    }

    $types = Get-ResourceTypesForProfile -ProfileName 'core'
    foreach ($type in $types) {
        Assert-True -Condition (-not $type.StartsWith('Microsoft.Network/')) `
            -Message "The core profile would deploy networking resource '$type'."
        Assert-True -Condition (-not $type.StartsWith('Microsoft.Compute/')) `
            -Message "The core profile would deploy compute resource '$type'."
        Assert-True -Condition (-not $type.StartsWith('Microsoft.DevTestLab/')) `
            -Message "The core profile would deploy DevTest Labs resource '$type'."
    }
}

Test-Case 'the core profile still deploys the conventions layer' {
    $types = Get-ResourceTypesForProfile -ProfileName 'core'

    foreach ($required in @(
            'Microsoft.Resources/resourceGroups',
            'Microsoft.OperationalInsights/workspaces',
            'Microsoft.Insights/components')) {
        Assert-True -Condition ($types -contains $required) `
            -Message "The core profile must deploy '$required'. Got: $($types -join ', ')"
    }
}

Test-Case 'the private profile adds the network and the private catalog modules' {
    $flags = Get-ProfileFeatureFlags -Template $template -ProfileName 'private'

    foreach ($flag in @('deployNetwork', 'deployKeyVault', 'deployStorage')) {
        Assert-Equal -Actual $flags[$flag] -Expected $true `
            -Message "The private profile must turn '$flag' on."
    }
    foreach ($flag in @('deployBastion', 'deployWindowsVm', 'deployLinuxVm',
            'deployNatGateway', 'deployEntraLogin', 'deployShutdownSchedules')) {
        Assert-Equal -Actual $flags[$flag] -Expected $false `
            -Message "The private profile must leave '$flag' off."
    }

    $types = Get-ResourceTypesForProfile -ProfileName 'private'
    Assert-True -Condition ($types -contains 'Microsoft.Network/virtualNetworks') `
        -Message 'The private profile must deploy a virtual network.'
    foreach ($type in $types) {
        Assert-True -Condition (-not $type.StartsWith('Microsoft.Compute/')) `
            -Message "The private profile would deploy compute resource '$type'."
    }

    # nat-gateway is instantiated so the network module can reference its output
    # without a dangling reference, but it is handed enabled=false and creates
    # nothing. The flag above is what actually decides, so assert the wiring.
    Assert-Equal -Actual $template.resources.natGateway.properties.parameters.enabled.value `
        -Expected "[variables('deployNatGateway')]" `
        -Message 'The nat-gateway module must be gated by deployNatGateway, not by the profile alone.'
}

Test-Case 'the full profile adds Bastion and the jumpboxes' {
    $flags = Get-ProfileFeatureFlags -Template $template -ProfileName 'full'

    foreach ($flag in @('deployNetwork', 'deployKeyVault', 'deployStorage', 'deployBastion',
            'deployWindowsVm', 'deployLinuxVm', 'deployNatGateway', 'deployEntraLogin',
            'deployShutdownSchedules', 'deployAnyVm')) {
        Assert-Equal -Actual $flags[$flag] -Expected $true `
            -Message "The full profile must turn '$flag' on."
    }

    $types = Get-ResourceTypesForProfile -ProfileName 'full'
    foreach ($required in @(
            'Microsoft.Network/bastionHosts',
            'Microsoft.Network/natGateways',
            'Microsoft.Compute/virtualMachines')) {
        Assert-True -Condition ($types -contains $required) `
            -Message "The full profile must deploy '$required'."
    }
}

Test-Case 'the deprecated minimal profile still resolves to private' {
    $legacy = Get-ProfileFeatureFlags -Template $template -ProfileName 'minimal'
    $private = Get-ProfileFeatureFlags -Template $template -ProfileName 'private'

    Assert-Equal -Actual $legacy.resolvedProfile -Expected 'private' `
        -Message "'minimal' must map to 'private' so environments provisioned before the ladder keep working."

    foreach ($flag in ($private.Keys | Where-Object { $_ -ne 'resolvedProfile' })) {
        Assert-Equal -Actual $legacy[$flag] -Expected $private[$flag] `
            -Message "'minimal' and 'private' disagree on '$flag'."
    }
}

Test-Case 'the profiles stay cumulative' {
    $core = @(Get-EnabledDeployments -Template $template `
            -Flags (Get-ProfileFeatureFlags -Template $template -ProfileName 'core'))
    $private = @(Get-EnabledDeployments -Template $template `
            -Flags (Get-ProfileFeatureFlags -Template $template -ProfileName 'private'))
    $full = @(Get-EnabledDeployments -Template $template `
            -Flags (Get-ProfileFeatureFlags -Template $template -ProfileName 'full'))

    foreach ($name in $core) {
        Assert-True -Condition ($private -contains $name) `
            -Message "The private profile drops '$name', so the ladder is not cumulative."
    }
    foreach ($name in $private) {
        Assert-True -Condition ($full -contains $name) `
            -Message "The full profile drops '$name', so the ladder is not cumulative."
    }
    Assert-True -Condition ($full.Count -gt $private.Count) `
        -Message 'The full profile must deploy more than the private profile.'
    Assert-True -Condition ($private.Count -gt $core.Count) `
        -Message 'The private profile must deploy more than the core profile.'
}

Test-Case 'every enabled module declares the profile it is enabled in' {
    foreach ($profileName in @('core', 'private', 'full')) {
        $flags = Get-ProfileFeatureFlags -Template $template -ProfileName $profileName
        foreach ($name in @(Get-EnabledDeployments -Template $template -Flags $flags)) {
            Assert-True -Condition ($deploymentToModule.ContainsKey($name)) `
                -Message "Deployment '$name' has no catalog module mapping in tests/bicep.tests.ps1."

            $moduleName = $deploymentToModule[$name]
            $module = $catalog.modules | Where-Object { $_.name -eq $moduleName }
            Assert-True -Condition ($null -ne $module) `
                -Message "Deployment '$name' maps to unknown catalog module '$moduleName'."
            Assert-True -Condition (@($module.profiles) -contains $profileName) `
                -Message "Module '$moduleName' runs in the '$profileName' profile but does not declare it."
        }
    }
}

Test-Case 'expert overrides still layer on top of the ladder' {
    $networkOnCore = Get-ProfileFeatureFlags -Template $template -ProfileName 'core' `
        -Overrides @{ network = $true }
    Assert-Equal -Actual $networkOnCore.deployNetwork -Expected $true `
        -Message 'An override must be able to add the network to a core deployment.'
    Assert-Equal -Actual $networkOnCore.deployBastion -Expected $false `
        -Message 'Overriding network must not pull in Bastion.'

    # Bastion needs a virtual network, so main.bicep derives the dependency.
    $bastionOnCore = Get-ProfileFeatureFlags -Template $template -ProfileName 'core' `
        -Overrides @{ bastion = $true }
    Assert-Equal -Actual $bastionOnCore.deployNetwork -Expected $true `
        -Message 'Enabling Bastion must derive the network it depends on.'

    # A jumpbox needs both the network and a Key Vault for its credentials.
    $vmOnCore = Get-ProfileFeatureFlags -Template $template -ProfileName 'core' `
        -Overrides @{ windowsVm = $true }
    Assert-Equal -Actual $vmOnCore.deployNetwork -Expected $true `
        -Message 'Enabling a jumpbox must derive the network it depends on.'
    Assert-Equal -Actual $vmOnCore.deployKeyVault -Expected $true `
        -Message 'Enabling a jumpbox must derive the Key Vault that holds its credentials.'

    $noNetworkOnFull = Get-ProfileFeatureFlags -Template $template -ProfileName 'full' `
        -Overrides @{ network = $false; bastion = $false; windowsVm = $false; linuxVm = $false }
    Assert-Equal -Actual $noNetworkOnFull.deployNetwork -Expected $false `
        -Message 'An override must be able to strip the network out of a full deployment.'
}

Test-Case 'role assignments can be turned off without touching the profile' {
    $flags = Get-ProfileFeatureFlags -Template $template -ProfileName 'full' -EnableRoleAssignments $false
    Assert-Equal -Actual $flags.assignRoles -Expected $false `
        -Message 'enableRoleAssignments=false must disable the operator RBAC assignments.'
    Assert-Equal -Actual $flags.deployWindowsVm -Expected $true `
        -Message 'Disabling role assignments must not change what is deployed.'
}
