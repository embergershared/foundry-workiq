[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Invoke-Azd {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Arguments
    )

    & azd @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd $($Arguments[0]) failed with exit code $LASTEXITCODE."
    }
}

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

. (Join-Path $PSScriptRoot 'naming.ps1')

# The deployment profile decides which of the values below are even relevant.
# 'minimal' is the pre-0.2.0 name for 'private' and is still accepted.
$deploymentProfile = (& azd env get-value DEPLOYMENT_PROFILE 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($deploymentProfile)) {
    $deploymentProfile = 'core'
}
$deploymentProfile = $deploymentProfile.Trim()
$resolvedProfile = if ($deploymentProfile -eq 'minimal') { 'private' } else { $deploymentProfile }

# The repository tag used to be hard-coded in infra/main.bicep, which meant
# every repository created from this template mislabelled its resources.
$repository = (& azd env get-value AZURE_REPOSITORY 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repository)) {
    $repository = Get-RepositoryName -Path (Split-Path -Parent $PSScriptRoot)
    Invoke-Azd -Arguments @('env', 'set', 'AZURE_REPOSITORY', $repository)
}

# A new environment targets the subscription the Azure CLI is signed in to, so
# deploying to another tenant or subscription is just az login / az account set.
$subscriptionId = (& azd env get-value AZURE_SUBSCRIPTION_ID 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
    $subscriptionId = Get-ActiveSubscriptionId
    if (-not $subscriptionId) {
        throw 'Unable to determine AZURE_SUBSCRIPTION_ID. Run az login and az account set --subscription <id>, or azd env set AZURE_SUBSCRIPTION_ID <id>.'
    }
    Invoke-Azd -Arguments @('env', 'set', 'AZURE_SUBSCRIPTION_ID', $subscriptionId)
    Write-Output "Initialized AZURE_SUBSCRIPTION_ID to $subscriptionId (source: active Azure CLI subscription)."
}
$subscriptionId = $subscriptionId.Trim()
Assert-DeploymentSubscription -SubscriptionId $subscriptionId

$subscriptionName = & az account show --subscription $subscriptionId `
    --query name --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionName)) {
    throw "Unable to read the display name for subscription '$subscriptionId'."
}
$derivedSubscriptionCode = Get-SubscriptionCode -SubscriptionName $subscriptionName -SubscriptionId $subscriptionId
$cachedSubscriptionCode = (& azd env get-value AZURE_SUBSCRIPTION_CODE 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cachedSubscriptionCode)) {
    Invoke-Azd -Arguments @('env', 'set', 'AZURE_SUBSCRIPTION_CODE', $derivedSubscriptionCode)
}
elseif ($cachedSubscriptionCode.Trim() -cne $derivedSubscriptionCode) {
    $null = Assert-SubscriptionCode -SubscriptionName $subscriptionName `
        -CachedCode $cachedSubscriptionCode -SubscriptionId $subscriptionId
}

$timeZone = [TimeZoneInfo]::FindSystemTimeZoneById(
    $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Eastern Standard Time' } else { 'America/New_York' })
)
$easternNow = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $timeZone)
$formattedNow = $easternNow.ToString(
    'yyyy-MM-ddTHH:mm:sszzz',
    [System.Globalization.CultureInfo]::InvariantCulture
)

$createdOn = (& azd env get-value AZURE_CREATED_ON 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($createdOn)) {
    Invoke-Azd -Arguments @('env', 'set', 'AZURE_CREATED_ON', $formattedNow)
}
else {
    $parsedCreatedOn = [DateTimeOffset]::MinValue
    $createdOnIsValid = [DateTimeOffset]::TryParseExact(
        $createdOn.Trim(),
        'yyyy-MM-ddTHH:mm:sszzz',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref] $parsedCreatedOn
    )
    if (-not $createdOnIsValid) {
        throw 'AZURE_CREATED_ON must be an ISO 8601 timestamp with the Eastern offset in effect at that instant.'
    }
    if ($parsedCreatedOn.Offset -ne $timeZone.GetUtcOffset($parsedCreatedOn.UtcDateTime)) {
        throw 'AZURE_CREATED_ON must be an ISO 8601 timestamp with the Eastern offset in effect at that instant.'
    }
}

Invoke-Azd -Arguments @('env', 'set', 'AZURE_LAST_UPDATED_ON', $formattedNow)

$featureOverridesJson = (& azd env get-value AZURE_FEATURE_OVERRIDES_JSON 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($featureOverridesJson)) {
    $featureOverridesJson = '{}'
    Invoke-Azd -Arguments @('env', 'set', 'AZURE_FEATURE_OVERRIDES_JSON', $featureOverridesJson)
}
$featureOverridesBase64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($featureOverridesJson.Trim())
)
Invoke-Azd -Arguments @('env', 'set', 'AZURE_FEATURE_OVERRIDES_BASE64', $featureOverridesBase64)

$operatorPrincipalIds = (& azd env get-value AZURE_OPERATOR_PRINCIPAL_IDS 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($operatorPrincipalIds)) {
    # Operator RBAC only matters once a jumpbox exists. In the core and private
    # profiles the Entra lookup is skipped entirely, so a deployment never needs
    # directory read permission it does not use.
    if ($resolvedProfile -eq 'full') {
        $signedInUserId = (& az ad signed-in-user show --query id --output tsv --only-show-errors 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($signedInUserId)) {
            $operatorPrincipalIds = $signedInUserId.Trim()
        }
        else {
            $operatorPrincipalIds = ''
        }
    }
    else {
        $operatorPrincipalIds = ''
    }

    Invoke-Azd -Arguments @('env', 'set', 'AZURE_OPERATOR_PRINCIPAL_IDS', $operatorPrincipalIds)
}
