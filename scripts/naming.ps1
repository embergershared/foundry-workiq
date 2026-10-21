function Get-SubscriptionCode {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionName,

        # Fallback source for subscriptions whose display name carries no code.
        [string] $SubscriptionId = ''
    )

    $code = Get-SubscriptionNameCode -SubscriptionName $SubscriptionName
    if ($code) {
        return $code
    }

    # Any tenant/subscription: derive a stable 5-character code from the subscription GUID.
    $parsedId = [Guid]::Empty
    if ([Guid]::TryParse($SubscriptionId, [ref] $parsedId)) {
        return "s$($parsedId.ToString('N').Substring(0, 4))"
    }

    throw "Subscription display name '$SubscriptionName' must end with a hyphen-delimited 1-4 digit token, such as '-1', contain an 's<N>' token, such as 'Contoso-s2-Projects', or a subscription ID must be supplied."
}

# The code a display name carries: a '-<N>' suffix ('Demo-3' => s3) or a delimited
# 's<N>' token ('Contoso-s2-Sandbox' => s2). Returns '' when there is none.
function Get-SubscriptionNameCode {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionName
    )

    $name = $SubscriptionName.Trim()
    $match = [regex]::Match($name, '-(?<number>[0-9]{1,4})$')
    if (-not $match.Success) {
        $match = [regex]::Match($name, '(?i)(?:^|[-_ ])s(?<number>[0-9]{1,4})(?:[-_ ]|$)')
    }
    if ($match.Success) {
        return "s$($match.Groups['number'].Value)"
    }

    return ''
}

function Assert-SubscriptionCode {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionName,

        [Parameter(Mandatory)]
        [string] $CachedCode,

        [string] $SubscriptionId = ''
    )

    # Names carrying no code accept an explicitly chosen one (azd env set AZURE_SUBSCRIPTION_CODE s1).
    if (-not (Get-SubscriptionNameCode -SubscriptionName $SubscriptionName) -and
        $CachedCode.Trim() -cmatch '^s[0-9a-z]{1,4}$') {
        return $CachedCode.Trim()
    }

    $derivedCode = Get-SubscriptionCode -SubscriptionName $SubscriptionName -SubscriptionId $SubscriptionId
    if ($CachedCode.Trim() -cne $derivedCode) {
        throw "Cached subscription code '$($CachedCode.Trim())' does not match '$derivedCode' derived from subscription '$SubscriptionName'."
    }

    return $derivedCode
}

# The subscription the Azure CLI is signed in to, or '' when there is none.
function Get-ActiveSubscriptionId {
    $active = & az account show --query id --output tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($active)) {
        return ''
    }

    return ([string] $active).Trim()
}

# The scripts query Azure through the az CLI while azd deploys with its own
# login, so both must target the same subscription (and therefore tenant).
function Assert-DeploymentSubscription {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $active = Get-ActiveSubscriptionId
    if (-not $active) {
        throw 'Unable to read the active Azure CLI subscription. Run az login.'
    }
    if ($active -ne $SubscriptionId.Trim()) {
        throw "The Azure CLI subscription '$active' differs from AZURE_SUBSCRIPTION_ID '$($SubscriptionId.Trim())'. Run: az account set --subscription $($SubscriptionId.Trim())"
    }
}

function Get-LocationCode {
    param(
        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [string] $CatalogPath
    )

    try {
        $catalog = Get-Content -LiteralPath $CatalogPath -Raw |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Unable to load the Azure location-code catalog '$CatalogPath': $($_.Exception.Message)"
    }

    $canonicalLocation = $Location.Trim().ToLowerInvariant()
    if (-not $catalog.ContainsKey($canonicalLocation)) {
        throw "Azure location '$Location' has no approved code in '$CatalogPath'."
    }

    $code = [string] $catalog[$canonicalLocation]
    if ($code -cnotmatch '^[a-z]{2}[a-z0-9]{0,3}$') {
        throw "Azure location '$canonicalLocation' has invalid code '$code'; codes must be 2-5 lowercase alphanumeric characters and start with two letters."
    }

    return $code
}

function Get-TenantCode {
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $CatalogPath
    )

    try {
        $catalog = Get-Content -LiteralPath $CatalogPath -Raw |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Unable to load the tenant-code catalog '$CatalogPath': $($_.Exception.Message)"
    }

    $canonicalTenant = $TenantId.Trim().ToLowerInvariant()
    if (-not $catalog.ContainsKey($canonicalTenant)) {
        throw "Tenant '$TenantId' has no approved code in '$CatalogPath'. Add it as `"<tenant-id>`": { `"name`": `"<display name>`", `"code`": `"<code>`" }."
    }

    # Names are lowercase; an empty code keeps the pre-tenant names for that tenant.
    $code = ([string] $catalog[$canonicalTenant].code).ToLowerInvariant()
    if ($code -cnotmatch '^([a-z0-9]{2,12})?$') {
        throw "Tenant '$canonicalTenant' has invalid code '$code'; codes must be empty or 2-12 lowercase alphanumeric characters."
    }

    return $code
}

# --------------------------------------------------------------------------
# PowerShell mirror of infra/core/naming.bicep.
#
# These functions must stay byte-for-byte equivalent to the Bicep exports.
# tests/naming.tests.ps1 renders the compiled ARM template and compares it to
# these, so a divergence fails the suite rather than silently producing a
# second naming convention.
# --------------------------------------------------------------------------

function Get-CoreCatalogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FileName
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $path = Join-Path $repoRoot "infra/core/$FileName"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Core catalog '$FileName' was not found at '$path'."
    }

    return $path
}

function Get-Abbreviation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Key,

        [string] $CatalogPath
    )

    if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
        $CatalogPath = Get-CoreCatalogPath -FileName 'abbreviations.json'
    }

    $catalog = Get-Content -LiteralPath $CatalogPath -Raw |
        ConvertFrom-Json -AsHashtable -ErrorAction Stop

    if (-not $catalog.ContainsKey($Key)) {
        throw "Resource type '$Key' has no approved abbreviation in '$CatalogPath'."
    }

    return [string] $catalog[$Key]
}

function Get-NormalizedEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $EnvironmentName
    )

    return $EnvironmentName.Replace('-', '').ToLowerInvariant()
}

function Get-BaseName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $TenantCode,
        [Parameter(Mandatory)] [string] $LocationCode,
        [Parameter(Mandatory)] [string] $SubscriptionCode,
        [Parameter(Mandatory)] [string] $EnvironmentName
    )

    if ([string]::IsNullOrEmpty($TenantCode)) {
        return "$LocationCode-$SubscriptionCode-$EnvironmentName"
    }

    return "$TenantCode-$LocationCode-$SubscriptionCode-$EnvironmentName"
}

function Get-AzName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Abbreviation,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $TenantCode,
        [Parameter(Mandatory)] [string] $LocationCode,
        [Parameter(Mandatory)] [string] $SubscriptionCode,
        [Parameter(Mandatory)] [string] $EnvironmentName,

        [AllowEmptyString()]
        [string] $Suffix = ''
    )

    $body = Get-BaseName -TenantCode $TenantCode -LocationCode $LocationCode `
        -SubscriptionCode $SubscriptionCode -EnvironmentName $EnvironmentName

    if ([string]::IsNullOrEmpty($Suffix)) {
        return "$Abbreviation-$body"
    }

    return "$Abbreviation-$body-$Suffix"
}

function Get-GlobalName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Abbreviation,
        [Parameter(Mandatory)] [string] $LocationCode,
        [Parameter(Mandatory)] [string] $SubscriptionCode,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [string] $ShortHash,

        [AllowEmptyString()]
        [string] $Separator = '-',

        [int] $Budget = 24
    )

    $fixed = "$Abbreviation$Separator$LocationCode$Separator$SubscriptionCode$Separator$Separator$ShortHash"
    $allowance = [Math]::Max(1, $Budget - $fixed.Length)
    $environment = Get-NormalizedEnvironment -EnvironmentName $EnvironmentName
    $trimmed = $environment.Substring(0, [Math]::Min($allowance, $environment.Length))

    return "$Abbreviation$Separator$LocationCode$Separator$SubscriptionCode$Separator$trimmed$Separator$ShortHash"
}

function Get-ShortName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Prefix,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [string] $ShortHash,

        [int] $Budget = 15
    )

    $allowance = [Math]::Max(1, $Budget - "$Prefix--$ShortHash".Length)
    $environment = Get-NormalizedEnvironment -EnvironmentName $EnvironmentName
    $trimmed = $environment.Substring(0, [Math]::Min($allowance, $environment.Length))

    return "$Prefix-$trimmed-$ShortHash"
}

function Get-ManagedResourceGroupName {
    <#
    .SYNOPSIS
        Mirrors managedResourceGroupName in infra/core/naming.bicep: the owning
        resource group name plus '-managed', for every platform-managed resource
        group (Container Apps infrastructure, AKS node resource group, ...).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroupName
    )

    return "$ResourceGroupName-managed"
}

function Get-CommonTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [string] $DeploymentProfile,
        [Parameter(Mandatory)] [string] $CreatedOn,
        [Parameter(Mandatory)] [string] $LastUpdatedOn,

        [AllowEmptyString()] [string] $Owner = '',
        [AllowEmptyString()] [string] $CostCenter = ''
    )

    $tags = [ordered] @{
        repository        = $Repository
        'azd-env-name'    = $EnvironmentName
        environment       = $EnvironmentName
        profile           = $DeploymentProfile
        'managed-by'      = 'azd'
        'created-on'      = $CreatedOn
        'last-updated-on' = $LastUpdatedOn
    }

    if (-not [string]::IsNullOrEmpty($Owner)) {
        $tags['owner'] = $Owner
    }

    if (-not [string]::IsNullOrEmpty($CostCenter)) {
        $tags['cost-center'] = $CostCenter
    }

    return $tags
}

function Get-TemplateVersion {
    [CmdletBinding()]
    param(
        [string] $AzureYamlPath
    )

    if ([string]::IsNullOrWhiteSpace($AzureYamlPath)) {
        $AzureYamlPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'azure.yaml'
    }

    if (-not (Test-Path -LiteralPath $AzureYamlPath)) {
        throw "Unable to determine the template version: '$AzureYamlPath' was not found."
    }

    $content = Get-Content -LiteralPath $AzureYamlPath -Raw
    $match = [regex]::Match($content, '(?m)^\s*template:\s*(?<name>[^@\s]+)@(?<version>[^\s]+)\s*$')
    if (-not $match.Success) {
        throw "'$AzureYamlPath' does not declare a 'metadata.template' value of the form '<name>@<version>'."
    }

    return [pscustomobject] @{
        Name    = $match.Groups['name'].Value
        Version = $match.Groups['version'].Value
        Stamp   = "$($match.Groups['name'].Value)@$($match.Groups['version'].Value)"
    }
}

function Get-RepositoryName {
    [CmdletBinding()]
    param(
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Split-Path -Parent $PSScriptRoot
    }

    $remote = $null
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $remote = & git -C $Path remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0) {
            $remote = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($remote)) {
        $trimmed = $remote.Trim() -replace '\.git$', ''
        # Accepts https://host/owner/repo, git@host:owner/repo and ssh://host/owner/repo.
        $match = [regex]::Match($trimmed, '(?<owner>[^/:]+)/(?<repo>[^/]+)$')
        if ($match.Success) {
            return "$($match.Groups['owner'].Value)/$($match.Groups['repo'].Value)"
        }
    }

    return (Split-Path -Leaf (Resolve-Path -LiteralPath $Path).Path)
}
