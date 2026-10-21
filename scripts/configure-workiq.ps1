<#
.SYNOPSIS
    Creates the Work IQ connection in the Foundry project (azd postprovision hook).

.DESCRIPTION
    Phase 2 of docs/workiq-deployment-plan.md. Runs after `azd provision` and
    does nothing unless the aiFoundry feature deployed a Foundry project. It:

      1. Reuses the Work IQ client secret stored in Key Vault, or adds a new
         password to the app registration and stores it in Key Vault.
      2. Creates the RemoteA2A / OAuth2 project connection to Work IQ. The
         connection cannot be edited, so it is deleted and recreated whenever
         its client secret changes.
      3. Adds the connection's OAuth redirect URL to the app registration.

    A connection this script created carries non-secret markers in its
    metadata (app ID, secret version and expiry). When they still match, the
    script changes nothing and never touches Key Vault, so a routine
    `azd provision` stays fast. A connection without the markers, for example
    one created in the portal, is replaced.

    Key Vault firewall: without a private endpoint the vault is public with a
    deny-by-default firewall. The script adds a /32 rule for this machine's
    public IP only while it reads or writes the secret, and removes it in a
    `finally` block. A vault with public access disabled is never opened; run
    the script from inside the virtual network instead (for example from the
    jumpbox).

    The client secret only ever exists in memory, in Key Vault, in the
    connection, and briefly in temporary files that are deleted in `finally`
    blocks. It is never passed on a command line, written to the azd
    environment, or printed.

.PARAMETER RotateSecret
    Create a new client secret and recreate the connection even when the
    current one is still valid. Old passwords this script added are removed
    afterwards.

.PARAMETER Force
    Recreate the connection even when its markers match.

.PARAMETER SecretValidityDays
    Lifetime of a new client secret.

.PARAMETER RenewWithinDays
    Rotate the secret automatically when it expires within this many days.

.EXAMPLE
    ./scripts/configure-workiq.ps1
.EXAMPLE
    ./scripts/configure-workiq.ps1 -RotateSecret
#>
[CmdletBinding()]
param(
    [switch] $RotateSecret,
    [switch] $Force,
    [ValidateRange(7, 730)]
    [int] $SecretValidityDays = 180,
    [ValidateRange(1, 180)]
    [int] $RenewWithinDays = 30
)

$ErrorActionPreference = 'Stop'

$connectionApiVersion = '2025-04-01-preview'
$defaultTarget = 'https://workiq.svc.cloud.microsoft/a2a/'
$workIqScopes = @('api://workiq.svc.cloud.microsoft/WorkIQAgent.Ask', 'offline_access')
$secretName = 'workiq-client-secret'

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
    if ([string]::IsNullOrWhiteSpace(($json -join ''))) { return $null }

    return ($json -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        return ''
    }

    return $value.Trim()
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Retries an operation that can fail while a new role assignment or
        firewall rule propagates.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Description,

        [Parameter(Mandatory)]
        [scriptblock] $Operation,

        [int] $Attempts = 12,
        [int] $DelaySeconds = 15
    )

    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Operation
        }
        catch {
            if ($attempt -ge $Attempts) { throw }
            # Write-Host, not Write-Output: the operation's result is this function's return value.
            Write-Host "$Description failed (attempt $attempt of $Attempts); waiting ${DelaySeconds}s for role or firewall propagation."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function New-TemporaryFilePath {
    return Join-Path ([IO.Path]::GetTempPath()) ('workiq-' + [guid]::NewGuid().ToString('N') + '.json')
}

function Remove-TemporaryFile {
    param(
        [AllowEmptyString()]
        [string] $Path
    )

    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Force }
}

# ---------------------------------------------------------------------------
# Key Vault firewall
# ---------------------------------------------------------------------------

function Open-KeyVaultFirewall {
    <#
    .SYNOPSIS
        Lets this machine reach the vault's data plane. Returns the rule it
        added, or an empty string when no rule was needed.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $VaultName
    )

    $vault = Invoke-AzJson -Arguments @(
        'keyvault', 'show', '--name', $VaultName,
        '--query', '{publicNetworkAccess:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, ipRules:properties.networkAcls.ipRules[].value}'
    )

    if ($vault.publicNetworkAccess -eq 'Disabled') {
        # A private vault stays private. Opening it would change the approved
        # network posture, so only a caller inside the VNet can continue.
        Write-Warning "Key Vault '$VaultName' has public network access disabled. Continuing only works from inside its virtual network (for example from the jumpbox)."
        return ''
    }
    if ($vault.defaultAction -ne 'Deny') {
        return ''
    }

    $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim()
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($publicIp, [ref] $parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Unable to determine this machine's public IPv4 address (got '$publicIp')."
    }

    $rule = "$publicIp/32"
    if (@($vault.ipRules) -contains $rule -or @($vault.ipRules) -contains $publicIp) {
        return ''
    }

    Write-Host "Temporarily allowing $rule through the Key Vault firewall."
    $null = Invoke-AzJson -Arguments @('keyvault', 'network-rule', 'add', '--name', $VaultName, '--ip-address', $rule)
    return $rule
}

function Close-KeyVaultFirewall {
    param(
        [Parameter(Mandatory)]
        [string] $VaultName,

        [AllowEmptyString()]
        [string] $Rule
    )

    if (-not $Rule) { return }

    Write-Output "Removing the temporary Key Vault firewall rule $Rule."
    & az keyvault network-rule remove --name $VaultName --ip-address $Rule --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Unable to remove the temporary Key Vault firewall rule $Rule. Remove it by hand: az keyvault network-rule remove --name $VaultName --ip-address $Rule"
    }
}

# ---------------------------------------------------------------------------
# Client secret
# ---------------------------------------------------------------------------

function Get-StoredSecret {
    <#
    .SYNOPSIS
        Returns the stored secret when it belongs to this app and is not about
        to expire, otherwise $null.
    #>
    param(
        [Parameter(Mandatory)] [string] $VaultName,
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [datetime] $RenewAfter
    )

    $exists = Invoke-WithRetry -Description 'Listing Key Vault secrets' -Operation {
        Invoke-AzJson -Arguments @('keyvault', 'secret', 'list', '--vault-name', $VaultName, '--query', "[?name=='$secretName'].name")
    }
    if (@($exists).Count -eq 0) { return $null }

    $secret = Invoke-WithRetry -Description 'Reading the Work IQ client secret' -Operation {
        Invoke-AzJson -Arguments @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', $secretName)
    }
    $expires = $secret.attributes.expires
    if (-not $secret.attributes.enabled -or
        $secret.tags.appId -ne $AppId -or
        -not $expires -or ([datetime] $expires).ToUniversalTime() -le $RenewAfter) {
        return $null
    }

    return [pscustomobject] @{
        Value     = $secret.value
        Version   = ($secret.id -split '/')[-1]
        KeyId     = $secret.tags.keyId
        ExpiresOn = ([datetime] $expires).ToUniversalTime()
    }
}

function New-StoredSecret {
    <#
    .SYNOPSIS
        Adds a password to the app registration and stores it in Key Vault.
    #>
    param(
        [Parameter(Mandatory)] [string] $VaultName,
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [int] $ValidityDays
    )

    $expiresOn = [datetime]::UtcNow.Date.AddDays($ValidityDays)
    $expiresText = $expiresOn.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)

    $requestPath = New-TemporaryFilePath
    $valuePath = New-TemporaryFilePath
    try {
        @{ passwordCredential = @{ displayName = $DisplayName; endDateTime = $expiresText } } |
            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $requestPath -Encoding utf8
        $credential = Invoke-AzJson -Arguments @(
            'rest', '--method', 'post',
            '--url', "https://graph.microsoft.com/v1.0/applications(appId='$AppId')/addPassword",
            '--headers', 'Content-Type=application/json',
            '--body', "@$requestPath"
        )
        Write-Host "Added client secret $($credential.keyId) to app $AppId, expiring $expiresText."

        # Written without a trailing newline so the stored value is exact.
        [IO.File]::WriteAllText($valuePath, $credential.secretText)
        $stored = Invoke-WithRetry -Description 'Storing the Work IQ client secret' -Operation {
            Invoke-AzJson -Arguments @(
                'keyvault', 'secret', 'set',
                '--vault-name', $VaultName,
                '--name', $secretName,
                '--file', $valuePath,
                '--encoding', 'utf-8',
                '--expires', $expiresText,
                '--content-type', 'text/plain',
                '--tags', "appId=$AppId", "keyId=$($credential.keyId)",
                '--query', 'id'
            )
        }
    }
    finally {
        Remove-TemporaryFile -Path $requestPath
        Remove-TemporaryFile -Path $valuePath
    }

    return [pscustomobject] @{
        Value     = $credential.secretText
        Version   = ([string] $stored -split '/')[-1]
        KeyId     = [string] $credential.keyId
        ExpiresOn = $expiresOn
    }
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

. (Join-Path $PSScriptRoot 'naming.ps1')

$projectId = Get-EnvironmentValue -Name 'FOUNDRY_PROJECT_ID'
if (-not $projectId) {
    Write-Output 'aiFoundry is not deployed in this environment; no Work IQ connection to configure.'
    return
}

$bootstrapHint = 'Run ./scripts/bootstrap-tenant.ps1 once for this tenant; see docs/workiq-deployment-plan.md.'
$appId = Get-EnvironmentValue -Name 'WORKIQ_APP_ID'
if (-not $appId) {
    throw "WORKIQ_APP_ID is not set. $bootstrapHint"
}
$vaultName = Get-EnvironmentValue -Name 'AZURE_KEY_VAULT_NAME'
if (-not $vaultName) {
    throw 'AZURE_KEY_VAULT_NAME is not set; the aiFoundry feature deploys the vault that holds the Work IQ client secret. Run azd provision.'
}
$subscriptionId = Get-EnvironmentValue -Name 'AZURE_SUBSCRIPTION_ID'
Assert-DeploymentSubscription -SubscriptionId $subscriptionId
$environmentName = Get-EnvironmentValue -Name 'AZURE_ENV_NAME'

$connectionName = Get-EnvironmentValue -Name 'WORKIQ_CONNECTION_NAME'
if (-not $connectionName) { $connectionName = 'workiq' }
if ($connectionName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{1,62}$') {
    throw "WORKIQ_CONNECTION_NAME '$connectionName' must be 2-63 letters, digits, hyphens or underscores."
}
$target = Get-EnvironmentValue -Name 'WORKIQ_TARGET'
if (-not $target) { $target = $defaultTarget }

$tenantId = (Invoke-AzJson -Arguments @('account', 'show', '--subscription', $subscriptionId, '--query', 'tenantId')).Trim()
$authority = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0"
$credentialDisplayName = "foundry-workiq-$environmentName"
$renewAfter = [datetime]::UtcNow.AddDays($RenewWithinDays)
$connectionUrl = "https://management.azure.com$projectId/connections/$($connectionName)?api-version=$connectionApiVersion"

$app = Invoke-AzJson -Arguments @('ad', 'app', 'show', '--id', $appId, '--query', '{objectId:id, redirectUris:web.redirectUris}')
if (-not $app) {
    throw "App registration '$appId' was not found in tenant $tenantId. $bootstrapHint"
}
$redirectUris = @($app.redirectUris | Where-Object { $_ })

# ---------------------------------------------------------------------------
# Fast path: the connection this script created is still current
# ---------------------------------------------------------------------------

$existing = $null
$existingJson = & az rest --method get --url $connectionUrl --only-show-errors --output json 2>$null
if ($LASTEXITCODE -eq 0 -and $existingJson) {
    $existing = ($existingJson -join [Environment]::NewLine) | ConvertFrom-Json
}

$existingRedirect = if ($existing) { [string] ($existing.properties.redirectUrl ?? $existing.properties.oauthRedirectUrl) } else { '' }
$isCurrent = $false
if ($existing -and -not $Force -and -not $RotateSecret) {
    $metadata = $existing.properties.metadata
    $markedExpiry = [datetime]::MinValue
    $hasExpiry = $metadata -and $metadata.PSObject.Properties['WorkIqSecretExpiresOn'] -and
        [datetime]::TryParse([string] $metadata.WorkIqSecretExpiresOn, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal, [ref] $markedExpiry)
    $isCurrent = $hasExpiry -and
        $metadata.PSObject.Properties['WorkIqAppId'] -and $metadata.WorkIqAppId -eq $appId -and
        $markedExpiry -gt $renewAfter -and
        $existing.properties.target -eq $target -and
        $existing.properties.authorizationUrl -eq "$authority/authorize" -and
        $existingRedirect -and $redirectUris -contains $existingRedirect
}

if ($isCurrent) {
    Write-Output "Work IQ connection '$connectionName' is current (secret expires $($existing.properties.metadata.WorkIqSecretExpiresOn)); nothing to change."
    $connection = $existing
}
else {
    if ($existing) {
        Write-Output "Work IQ connection '$connectionName' is missing its markers, outdated or forced; it will be recreated."
    }

    # -----------------------------------------------------------------------
    # Secret: reuse the stored one, or create and store a new one
    # -----------------------------------------------------------------------

    $firewallRule = Open-KeyVaultFirewall -VaultName $vaultName
    try {
        $secret = if ($RotateSecret) { $null } else {
            Get-StoredSecret -VaultName $vaultName -AppId $appId -RenewAfter $renewAfter
        }
        $createdSecret = $false
        if (-not $secret) {
            $secret = New-StoredSecret -VaultName $vaultName -AppId $appId `
                -DisplayName $credentialDisplayName -ValidityDays $SecretValidityDays
            $createdSecret = $true
        }
        else {
            Write-Output "Reusing the Work IQ client secret stored in Key Vault (version $($secret.Version))."
        }
    }
    finally {
        Close-KeyVaultFirewall -VaultName $vaultName -Rule $firewallRule
    }

    # -----------------------------------------------------------------------
    # Connection: delete and recreate, because it cannot be edited
    # -----------------------------------------------------------------------

    if ($existing) {
        Write-Output "Deleting Work IQ connection '$connectionName'."
        & az rest --method delete --url $connectionUrl --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw "Unable to delete Work IQ connection '$connectionName'." }
    }

    $body = @{
        name       = $connectionName
        properties = @{
            authType         = 'OAuth2'
            group            = 'ServicesAndApps'
            category         = 'RemoteA2A'
            target           = $target
            isSharedToAll    = $true
            sharedUserList   = @()
            AuthorizationUrl = "$authority/authorize"
            TokenUrl         = "$authority/token"
            RefreshUrl       = "$authority/token"
            Scopes           = $workIqScopes
            Credentials      = @{
                ClientId     = $appId
                ClientSecret = $secret.Value
            }
            # Non-secret markers that let the next run skip Key Vault entirely.
            metadata         = @{
                ApiType                = 'Azure'
                WorkIqAppId            = $appId
                WorkIqSecretVersion    = $secret.Version
                WorkIqSecretExpiresOn  = $secret.ExpiresOn.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
    }

    $bodyPath = New-TemporaryFilePath
    try {
        $body | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bodyPath -Encoding utf8
        Write-Output "Creating Work IQ connection '$connectionName' to $target."
        $connection = Invoke-WithRetry -Description 'Creating the Work IQ connection' -Operation {
            Invoke-AzJson -Arguments @(
                'rest', '--method', 'put',
                '--url', $connectionUrl,
                '--headers', 'Content-Type=application/json',
                '--body', "@$bodyPath"
            )
        }
    }
    finally {
        Remove-TemporaryFile -Path $bodyPath
        $body = $null
        if ($secret) { $secret.Value = $null }
    }

    # A new secret is in use, so the passwords this script added earlier for
    # this environment are no longer needed.
    if ($createdSecret) {
        $stale = @(Invoke-AzJson -Arguments @(
                'ad', 'app', 'credential', 'list', '--id', $appId,
                '--query', "[?displayName=='$credentialDisplayName' && keyId!='$($secret.KeyId)'].keyId"
            ))
        foreach ($keyId in $stale) {
            Write-Output "Removing superseded client secret $keyId from app $appId."
            & az ad app credential delete --id $appId --key-id $keyId --only-show-errors --output none
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Unable to remove superseded client secret $keyId; remove it by hand."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Redirect URI
# ---------------------------------------------------------------------------

$redirectUrl = [string] ($connection.properties.redirectUrl ?? $connection.properties.oauthRedirectUrl)
if (-not $redirectUrl) {
    throw "Work IQ connection '$connectionName' returned no OAuth redirect URL."
}

$previousRedirect = Get-EnvironmentValue -Name 'WORKIQ_REDIRECT_URI'
$wantedRedirectUris = @($redirectUris | Where-Object { -not ($previousRedirect -and $_ -eq $previousRedirect -and $_ -ne $redirectUrl) })
if ($wantedRedirectUris -notcontains $redirectUrl) { $wantedRedirectUris += $redirectUrl }

if ((($redirectUris | Sort-Object) -join "`n") -cne (($wantedRedirectUris | Sort-Object) -join "`n")) {
    Write-Output "Setting the app registration's web redirect URIs to include $redirectUrl."
    & az ad app update --id $appId --web-redirect-uris @wantedRedirectUris --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw "Unable to update the redirect URIs of app '$appId'." }
}

Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_CONNECTION_NAME', $connectionName)
Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_CONNECTION_ID', [string] $connection.id)
Invoke-Azd -Arguments @('env', 'set', 'WORKIQ_REDIRECT_URI', $redirectUrl)

Write-Output "Work IQ connection '$connectionName' is ready. Each user consents to it on first use."
