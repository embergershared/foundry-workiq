<#
.SYNOPSIS
    Creates the Foundry Work IQ connection and wires it to the Work IQ app
    registration.

.DESCRIPTION
    Runs as the azd postprovision hook, and does nothing unless the aiFoundry
    feature deployed a Foundry project. Phase 2 of
    docs/workiq-deployment-plan.md:

      1. Adds a client secret to the Work IQ app registration from
         scripts/bootstrap-tenant.ps1 and stores it in the Key Vault.
      2. Creates the RemoteA2A / OAuth2 project connection to Work IQ.
      3. Adds the connection's OAuth redirect URL to the app registration.

    The connection's fields can't be edited after creation, and the Key Vault
    accepts no data-plane traffic from outside its virtual network, so the
    secret is never read back. A new secret is created only when the
    connection has to be created or recreated, written to the vault through
    Azure Resource Manager and passed straight to the connection. It never
    appears in output, on a command line or in the azd environment. When the
    connection exists, the stored secret is tagged with the current app and it
    does not expire within -RenewWithinDays, only the redirect URI is checked.
    A secret that is about to expire is replaced, so a routine `azd provision`
    rotates it before the connection stops working.

.PARAMETER ConnectionName
    Name of the project connection. Defaults to WORKIQ_CONNECTION_NAME, then
    'workiq'.

.PARAMETER Target
    Work IQ A2A endpoint.

.PARAMETER SecretLifetimeYears
    Lifetime of a new client secret.

.PARAMETER RenewWithinDays
    Recreate the connection with a new secret when the stored one expires
    within this many days.

.PARAMETER Force
    Recreate the connection and its secret even when they look current.

.EXAMPLE
    ./scripts/configure-workiq.ps1
.EXAMPLE
    ./scripts/configure-workiq.ps1 -Force
#>
[CmdletBinding()]
param(
    [string] $ConnectionName,
    [string] $Target = 'https://workiq.svc.cloud.microsoft/a2a/',
    [ValidateRange(1, 2)]
    [int] $SecretLifetimeYears = 1,
    [ValidateRange(1, 180)]
    [int] $RenewWithinDays = 30,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$connectionApiVersion = '2025-04-01-preview'
$keyVaultApiVersion = '2024-11-01'
$secretName = 'workiq-client-secret'
$scopes = @('api://workiq.svc.cloud.microsoft/WorkIQAgent.Ask', 'offline_access')

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
        throw "az $($Arguments[0..1] -join ' ') failed with exit code $LASTEXITCODE."
    }
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }

    return $json | ConvertFrom-Json
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [switch] $Required
    )

    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        if ($Required) { throw "Required azd environment value '$Name' is not set." }
        return ''
    }

    return $value.Trim()
}

# GET through az rest, returning $null for a 404 instead of failing. Every
# URL here is free of parentheses: on Windows az is a batch file and cmd.exe
# rejects them unquoted.
function Get-ArmResource {
    param(
        [Parameter(Mandatory)]
        [string] $Url
    )

    $output = & az rest --method get --url $Url --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -eq 0) { return ($output | Out-String | ConvertFrom-Json) }
    if (($output | Out-String) -match '\(NotFound\)|Not Found|ResourceNotFound|SecretNotFound|404') { return $null }
    throw "az rest GET $Url failed: $(($output | Out-String).Trim())"
}

# PUT a body that may hold a secret. The body goes through a temporary file
# that is deleted in all cases, so the value never reaches a command line.
function Invoke-ArmPut {
    param(
        [Parameter(Mandatory)]
        [string] $Url,
        [Parameter(Mandatory)]
        [hashtable] $Body
    )

    $bodyPath = Join-Path ([IO.Path]::GetTempPath()) ('workiq-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $Body | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyPath -Encoding utf8
        return Invoke-AzJson -Arguments @('rest', '--method', 'put', '--url', $Url, '--body', "@$bodyPath")
    }
    finally {
        if (Test-Path -LiteralPath $bodyPath) { Remove-Item -LiteralPath $bodyPath -Force }
    }
}

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

. (Join-Path $PSScriptRoot 'naming.ps1')

$accountName = Get-EnvironmentValue -Name 'FOUNDRY_ACCOUNT_NAME'
if (-not $accountName) {
    Write-Output 'aiFoundry is not deployed in this environment; skipping the Work IQ connection.'
    return
}

$subscriptionId = Get-EnvironmentValue -Name 'AZURE_SUBSCRIPTION_ID' -Required
$resourceGroup = Get-EnvironmentValue -Name 'AZURE_RESOURCE_GROUP' -Required
$projectName = Get-EnvironmentValue -Name 'FOUNDRY_PROJECT_NAME' -Required
$keyVaultName = Get-EnvironmentValue -Name 'AZURE_KEY_VAULT_NAME' -Required
$appId = Get-EnvironmentValue -Name 'WORKIQ_APP_ID' -Required
$environmentName = Get-EnvironmentValue -Name 'AZURE_ENV_NAME' -Required
if (-not $ConnectionName) { $ConnectionName = Get-EnvironmentValue -Name 'WORKIQ_CONNECTION_NAME' }
if (-not $ConnectionName) { $ConnectionName = 'workiq' }
if ($ConnectionName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{1,31}$') {
    throw "Invalid connection name '$ConnectionName'. Use 2-32 letters, digits, hyphens or underscores."
}
Assert-DeploymentSubscription -SubscriptionId $subscriptionId
$tenantId = (Invoke-AzJson -Arguments @('account', 'show', '--query', 'tenantId')).Trim()

$resourceGroupUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
$connectionUrl = "$resourceGroupUrl/providers/Microsoft.CognitiveServices/accounts/$accountName/projects/$projectName/connections/${ConnectionName}?api-version=$connectionApiVersion"
$secretUrl = "$resourceGroupUrl/providers/Microsoft.KeyVault/vaults/$keyVaultName/secrets/${secretName}?api-version=$keyVaultApiVersion"
# One credential name per environment, so a recreate only removes this
# environment's old secrets from an app that several environments share.
$credentialName = "foundry-workiq-$environmentName"

# ---------------------------------------------------------------------------
# 1. Decide whether the connection must be (re)created
# ---------------------------------------------------------------------------

$connection = Get-ArmResource -Url $connectionUrl
$storedSecret = Get-ArmResource -Url $secretUrl
$secretClientId = if ($storedSecret -and $storedSecret.PSObject.Properties['tags'] -and $storedSecret.tags) {
    $storedSecret.tags.clientId
}
else { '' }

# Resource Manager returns the secret's attributes, never its value, so the
# expiry is read without any data-plane access to the vault.
$secretExpires = $null
if ($storedSecret -and $storedSecret.PSObject.Properties['properties'] -and
    $storedSecret.properties.PSObject.Properties['attributes'] -and
    $storedSecret.properties.attributes.PSObject.Properties['exp'] -and $storedSecret.properties.attributes.exp) {
    $secretExpires = [DateTimeOffset]::FromUnixTimeSeconds([long] $storedSecret.properties.attributes.exp)
}
$expiresSoon = $secretClientId -eq $appId -and
    (-not $secretExpires -or $secretExpires -le [DateTimeOffset]::UtcNow.AddDays($RenewWithinDays))

$isCurrent = $connection -and $connection.properties.target -eq $Target -and $secretClientId -eq $appId -and -not $expiresSoon
if ($isCurrent -and -not $Force) {
    Write-Output "Connection '$ConnectionName' is current for app $appId; its secret expires $($secretExpires.ToString('yyyy-MM-dd'))."
}
else {
    if ($connection -and $expiresSoon -and -not $Force) {
        $when = if ($secretExpires) { "expires $($secretExpires.ToString('yyyy-MM-dd'))" } else { 'has no expiry date' }
        Write-Output "The stored client secret $when, within the $RenewWithinDays-day renewal window; rotating it."
    }
    if ($connection) {
        # The connection's fields can't be edited after creation.
        Write-Output "Recreating connection '$ConnectionName'."
        $null = Invoke-AzJson -Arguments @('rest', '--method', 'delete', '--url', $connectionUrl)
    }
    else {
        Write-Output "Creating connection '$ConnectionName' to $Target."
    }

    # -----------------------------------------------------------------------
    # 2. New client secret, held only in memory and the Key Vault
    # -----------------------------------------------------------------------

    $credential = Invoke-AzJson -Arguments @(
        'ad', 'app', 'credential', 'reset', '--id', $appId, '--append',
        '--display-name', $credentialName, '--years', "$SecretLifetimeYears"
    )
    $clientSecret = $credential.password
    $credential = $null
    if ([string]::IsNullOrWhiteSpace($clientSecret)) {
        throw "Adding a client secret to app $appId returned no value."
    }

    try {
        $expires = [DateTimeOffset]::UtcNow.AddYears($SecretLifetimeYears).AddDays(-1).ToUnixTimeSeconds()
        $null = Invoke-ArmPut -Url $secretUrl -Body @{
            tags       = @{ clientId = $appId; connection = $ConnectionName }
            properties = @{
                value       = $clientSecret
                contentType = "Client secret of the Work IQ app $appId"
                attributes  = @{ enabled = $true; exp = $expires }
            }
        }
        Write-Output "Stored the client secret as '$secretName' in Key Vault '$keyVaultName'."

        # -------------------------------------------------------------------
        # 3. The connection, with the body from the Work IQ article
        # -------------------------------------------------------------------

        $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        $connection = Invoke-ArmPut -Url $connectionUrl -Body @{
            tags       = $null
            location   = $null
            name       = $ConnectionName
            type       = 'Microsoft.MachineLearningServices/workspaces/connections'
            properties = @{
                authType         = 'OAuth2'
                group            = 'ServicesAndApps'
                category         = 'RemoteA2A'
                expiryTime       = $null
                target           = $Target
                isSharedToAll    = $true
                sharedUserList   = @()
                TokenUrl         = $tokenUrl
                AuthorizationUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/authorize"
                RefreshUrl       = $tokenUrl
                Scopes           = $scopes
                Credentials      = @{ ClientId = $appId; ClientSecret = $clientSecret }
                metadata         = @{ ApiType = 'Azure' }
            }
        }
    }
    finally {
        $clientSecret = $null
    }
    Write-Output "Connection '$ConnectionName' created."

    # The previous secrets of this environment belonged to the deleted
    # connection, so nothing uses them any more.
    # Filtered here rather than in --query: cmd.exe would split on its &&.
    $ownCredentials = @(Invoke-AzJson -Arguments @('ad', 'app', 'credential', 'list', '--id', $appId) |
            Where-Object { $_.displayName -eq $credentialName } |
            Sort-Object { [DateTimeOffset] $_.startDateTime })
    $oldKeyIds = @($ownCredentials | Select-Object -SkipLast 1 | ForEach-Object { $_.keyId })
    foreach ($keyId in $oldKeyIds) {
        $null = Invoke-AzJson -Arguments @('ad', 'app', 'credential', 'delete', '--id', $appId, '--key-id', $keyId)
        Write-Output "Removed the superseded client secret $keyId."
    }
}

# ---------------------------------------------------------------------------
# 4. Redirect URI on the app registration
# ---------------------------------------------------------------------------

# The article names the field oauthRedirectUrl; api-version
# 2025-04-01-preview returns it as redirectUrl. Accept either.
function Get-RedirectUrl {
    param($Resource)

    if (-not $Resource) { return '' }
    foreach ($name in @('redirectUrl', 'oauthRedirectUrl')) {
        $property = $Resource.properties.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace($property.Value)) { return $property.Value }
    }
    return ''
}

$redirectUri = Get-RedirectUrl $connection
if (-not $redirectUri) { $redirectUri = Get-RedirectUrl (Get-ArmResource -Url $connectionUrl) }
if (-not $redirectUri) {
    throw "Connection '$ConnectionName' returned no redirect URL."
}

$app = Invoke-AzJson -Arguments @('ad', 'app', 'show', '--id', $appId, '--query', '{id: id, redirectUris: web.redirectUris}')
$redirectUris = @($app.redirectUris | Where-Object { $_ })
if ($redirectUris -notcontains $redirectUri) {
    # A Graph PATCH with a body file, because the URL can carry characters
    # such as & that cmd.exe would split on as --web-redirect-uris arguments.
    $merged = @(@($redirectUris) + $redirectUri | Sort-Object -Unique)
    $bodyPath = Join-Path ([IO.Path]::GetTempPath()) ('workiq-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        @{ web = @{ redirectUris = $merged } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $bodyPath -Encoding utf8
        $null = Invoke-AzJson -Arguments @(
            'rest', '--method', 'patch',
            '--url', "https://graph.microsoft.com/v1.0/applications/$($app.id)",
            '--headers', 'Content-Type=application/json',
            '--body', "@$bodyPath"
        )
    }
    finally {
        if (Test-Path -LiteralPath $bodyPath) { Remove-Item -LiteralPath $bodyPath -Force }
    }
    Write-Output "Added the redirect URI to app $appId."
}
else {
    Write-Output "App $appId already has the redirect URI."
}

# The bootstrap reads the app's redirect URIs too; this keeps a record next to
# the other Work IQ values.
Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_CONNECTION_NAME', $ConnectionName)
Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_REDIRECT_URI', $redirectUri)
Write-Output "Work IQ connection '$ConnectionName' is ready. Each user grants their own consent on first use."
