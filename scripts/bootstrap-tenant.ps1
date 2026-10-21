<#
.SYNOPSIS
    One-time Work IQ tenant bootstrap for the Foundry Work IQ connection.

.DESCRIPTION
    Run once per tenant, by an administrator, before the first `azd provision`
    that enables the aiFoundry feature. The script:

      1. Confirms the signed-in user holds an active Global Administrator role
         (activate it through PIM first), unless -SkipRoleCheck is passed.
      2. Provisions the Work IQ service principal if the tenant does not have
         it yet.
      3. Deploys infra/entra/main.bicep: the single-tenant app registration with
         the delegated WorkIQAgent.Ask permission, its service principal,
         tenant-wide admin consent, and the Work IQ users security group.
      4. Writes the app and group IDs to the selected azd environment, where
         infra/main.parameters.json picks them up.

    The script is idempotent. Re-running it keeps redirect URIs already on the
    app registration, so it never undoes the redirect URI that a Foundry
    connection added.

    Copilot Credits usage-based billing has no API and stays a manual step in
    the Microsoft 365 admin center; see docs/workiq-deployment-plan.md.

.PARAMETER UserObjectIds
    Entra user object IDs to add to the Work IQ users group. The signed-in user
    is always added.

.PARAMETER RedirectUris
    Additional web redirect URIs for the app registration. Existing URIs on the
    app are kept.

.PARAMETER AppUniqueName
    Stable key of the app registration. Use a different value to get a separate
    app, for example one per environment.

.PARAMETER UsersGroupUniqueName
    Stable key of the Work IQ users security group.

.PARAMETER SkipRoleCheck
    Skip the Global Administrator check, for tenants that delegate consent to a
    lower role such as Cloud Application Administrator.

.EXAMPLE
    ./scripts/bootstrap-tenant.ps1
.EXAMPLE
    ./scripts/bootstrap-tenant.ps1 -UserObjectIds 00000000-0000-0000-0000-000000000001
#>
[CmdletBinding()]
param(
    [string[]] $UserObjectIds = @(),
    [string[]] $RedirectUris = @(),
    [ValidateLength(1, 64)]
    [string] $AppUniqueName = 'foundry-workiq',
    [ValidateLength(1, 64)]
    [string] $UsersGroupUniqueName = 'foundry-workiq-users',
    [switch] $SkipRoleCheck
)

$ErrorActionPreference = 'Stop'

$workIqAppId = 'fdcc1f02-fc51-4226-8753-f668596af7f7'
$workIqScope = 'WorkIQAgent.Ask'
$globalAdministratorTemplateId = '62e90394-69f5-4237-9190-012177145e10'

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

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $json = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return $json | ConvertFrom-Json
}

function Get-RequiredEnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value '$Name' is not set."
    }

    return $value.Trim()
}

function Assert-ObjectId {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParseExact($Value, 'D', [ref] $parsed) -or $parsed -eq [Guid]::Empty) {
        throw "Invalid Entra object ID '$Value'."
    }
}

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

. (Join-Path $PSScriptRoot 'naming.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$subscriptionId = Get-RequiredEnvironmentValue -Name 'AZURE_SUBSCRIPTION_ID'
$location = Get-RequiredEnvironmentValue -Name 'AZURE_LOCATION'
Assert-DeploymentSubscription -SubscriptionId $subscriptionId

foreach ($objectId in $UserObjectIds) { Assert-ObjectId -Value $objectId }

$signedInUserId = (Invoke-AzJson -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id')).Trim()
Assert-ObjectId -Value $signedInUserId

# ---------------------------------------------------------------------------
# 1. Privilege check
# ---------------------------------------------------------------------------

if (-not $SkipRoleCheck) {
    # PIM-activated roles appear here only while the activation is current.
    $roles = Invoke-AzJson -Arguments @(
        'rest', '--method', 'get',
        '--url', 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=roleTemplateId'
    )
    $isGlobalAdministrator = @($roles.value | Where-Object { $_.roleTemplateId -eq $globalAdministratorTemplateId }).Count -gt 0
    if (-not $isGlobalAdministrator) {
        throw 'The signed-in user has no active Global Administrator role. Activate it through Microsoft Entra PIM, run az login again, and retry. Use -SkipRoleCheck only if your tenant delegates admin consent to a lower role.'
    }
}

# ---------------------------------------------------------------------------
# 2. Work IQ service principal
# ---------------------------------------------------------------------------

$null = & az ad sp show --id $workIqAppId --only-show-errors --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Output "Provisioning the Work IQ service principal ($workIqAppId)."
    $null = Invoke-AzJson -Arguments @('ad', 'sp', 'create', '--id', $workIqAppId)
}
else {
    Write-Output "The Work IQ service principal ($workIqAppId) already exists."
}

$workIqScopes = @(Invoke-AzJson -Arguments @(
        'ad', 'sp', 'show', '--id', $workIqAppId,
        '--query', "oauth2PermissionScopes[?value=='$workIqScope'].id"
    ))
if ($workIqScopes.Count -eq 0) {
    throw "The Work IQ service principal does not expose the '$workIqScope' delegated permission."
}

# ---------------------------------------------------------------------------
# 3. App registration, consent and users group
# ---------------------------------------------------------------------------

# Keep the redirect URIs already on the app. Each Foundry connection adds its
# own after it is created, and the Graph deployment would otherwise drop them.
$existingRedirectUris = @()
$existingApp = & az rest --method get `
    --url "https://graph.microsoft.com/v1.0/applications(uniqueName='$AppUniqueName')?`$select=web" `
    --only-show-errors --output json 2>$null
if ($LASTEXITCODE -eq 0 -and $existingApp) {
    $existingRedirectUris = @(($existingApp | ConvertFrom-Json).web.redirectUris)
}
$allRedirectUris = @(@($existingRedirectUris) + @($RedirectUris) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Sort-Object -Unique)

$members = @(@($signedInUserId) + @($UserObjectIds) | Sort-Object -Unique)

$parameters = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        appUniqueName        = @{ value = $AppUniqueName }
        usersGroupUniqueName = @{ value = $UsersGroupUniqueName }
        ownerObjectIds       = @{ value = @($signedInUserId) }
        userObjectIds        = @{ value = $members }
        redirectUris         = @{ value = $allRedirectUris }
    }
}

# The parameters file holds object IDs and URIs only, never a secret.
$parametersPath = Join-Path ([IO.Path]::GetTempPath()) ("workiq-entra-" + [guid]::NewGuid().ToString('N') + '.json')
try {
    $parameters | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $parametersPath -Encoding utf8
    Write-Output "Deploying infra/entra/main.bicep to subscription $subscriptionId."
    $deployment = Invoke-AzJson -Arguments @(
        'deployment', 'sub', 'create',
        '--name', "workiq-entra-$AppUniqueName",
        '--location', $location,
        '--template-file', (Join-Path $repoRoot 'infra/entra/main.bicep'),
        '--parameters', "@$parametersPath"
    )
}
finally {
    if (Test-Path -LiteralPath $parametersPath) { Remove-Item -LiteralPath $parametersPath -Force }
}

$outputs = $deployment.properties.outputs

# ---------------------------------------------------------------------------
# 4. Hand the IDs to azd
# ---------------------------------------------------------------------------

Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_APP_ID', $outputs.appId.value)
Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_APP_OBJECT_ID', $outputs.appObjectId.value)
Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_USERS_GROUP_ID', $outputs.usersGroupId.value)

Write-Output "Work IQ app registration: $($outputs.appId.value)."
Write-Output "Work IQ users group: $($outputs.usersGroupId.value)."
Write-Output 'Remaining manual step: enable Copilot Credits usage-based billing in the Microsoft 365 admin center and add the Work IQ users group to a spending policy that includes the Work IQ API.'
