# Behaviour of scripts/configure-workiq.ps1, the azd postprovision hook that
# creates the Work IQ connection.
#
# az, azd, Invoke-RestMethod and Start-Sleep are replaced with recording stubs,
# so the cases run offline and prove what the script sends where: in
# particular that the client secret never reaches a command line and that the
# temporary Key Vault firewall rule is always removed.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')

# Read through dynamic scoping, never with a scope modifier: the stubs run
# inside configure-workiq.ps1, where $script: is that script's own scope.
$WorkIqFixture = @{
    ConfigureScript = Get-RepoPath 'scripts/configure-workiq.ps1'
    SubscriptionId  = '11111111-1111-1111-1111-111111111111'
    TenantId        = '22222222-2222-2222-2222-222222222222'
    AppId           = '33333333-3333-3333-3333-333333333333'
    RedirectUrl     = 'https://global.consent.azure-apim.net/redirect/fixture-workiq'
    SecretText      = 'fixture-secret-' + [guid]::NewGuid().ToString('N')
}
$WorkIqFixture.ProjectId = "/subscriptions/$($WorkIqFixture.SubscriptionId)/resourceGroups/rg-fixture/providers/Microsoft.CognitiveServices/accounts/aif-fixture/projects/proj-fixture"

function New-WorkIqState {
    <#
    .SYNOPSIS
        The mutable world the stubs read and write for one test case.
    #>
    param(
        [hashtable] $Connection,
        [string] $VaultAccess = 'Enabled',
        [string[]] $AppRedirectUris = @()
    )

    return @{
        Env        = @{
            FOUNDRY_PROJECT_ID    = $WorkIqFixture.ProjectId
            WORKIQ_APP_ID         = $WorkIqFixture.AppId
            AZURE_KEY_VAULT_NAME  = 'kv-fixture'
            AZURE_SUBSCRIPTION_ID = $WorkIqFixture.SubscriptionId
            AZURE_ENV_NAME        = 'fixture'
        }
        Connection = $Connection
        Vault      = @{ publicNetworkAccess = $VaultAccess; defaultAction = 'Deny'; ipRules = @() }
        Redirects  = $AppRedirectUris
        Calls      = [System.Collections.Generic.List[string]]::new()
        Files      = [System.Collections.Generic.List[string]]::new()
        PutBody    = $null
        StoredText = $null
    }
}

function Invoke-ConfigureWorkIq {
    <#
    .SYNOPSIS
        Runs the real script against recording stubs and returns its output.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [string[]] $Arguments = @()
    )

    function azd {
        $global:LASTEXITCODE = 0
        if ($args[0] -ne 'env') { throw "Unexpected azd call: $args" }
        if ($args[1] -eq 'set') { $State.Env[$args[2]] = [string] $args[3]; return }
        if ($args[1] -eq 'get-value') {
            if ($State.Env.ContainsKey($args[2])) { return $State.Env[$args[2]] }
            $global:LASTEXITCODE = 1
            return
        }
        throw "Unexpected azd call: $args"
    }

    function az {
        $global:LASTEXITCODE = 0
        $line = $args -join ' '
        $State.Calls.Add($line)
        foreach ($argument in $args) {
            if ([string] $argument -like '@*') { $State.Files.Add(([string] $argument).Substring(1)) }
        }
        $fileIndex = [array]::IndexOf($args, '--file')
        if ($fileIndex -ge 0) { $State.Files.Add([string] $args[$fileIndex + 1]) }

        switch -Wildcard ($line) {
            'account show --query id*' { return $WorkIqFixture.SubscriptionId }
            'account show --subscription*' { return "`"$($WorkIqFixture.TenantId)`"" }
            'ad app show*' {
                return (@{ objectId = 'app-object'; redirectUris = @($State.Redirects) } | ConvertTo-Json -Compress)
            }
            'ad app update*' {
                $index = [array]::IndexOf($args, '--web-redirect-uris')
                $State.Redirects = @($args[($index + 1)..($args.Count - 1)] | Where-Object { $_ -notlike '--*' -and $_ -ne 'none' })
                return
            }
            'ad app credential list*' { return '["old-key"]' }
            'ad app credential delete*' { return }
            'rest --method get*' {
                if (-not $State.Connection) { $global:LASTEXITCODE = 3; return }
                return ($State.Connection | ConvertTo-Json -Depth 6 -Compress)
            }
            'rest --method delete*' { $State.Connection = $null; return }
            'rest --method post*addPassword*' {
                return (@{ keyId = 'new-key'; secretText = $WorkIqFixture.SecretText } | ConvertTo-Json -Compress)
            }
            'rest --method put*' {
                $bodyPath = ([string] ($args | Where-Object { [string] $_ -like '@*' })).Substring(1)
                $State.PutBody = Get-Content -LiteralPath $bodyPath -Raw | ConvertFrom-Json -AsHashtable
                $properties = $State.PutBody.properties
                $State.Connection = @{
                    id         = "$($WorkIqFixture.ProjectId)/connections/$($State.PutBody.name)"
                    properties = @{
                        target           = $properties.target
                        authorizationUrl = $properties.AuthorizationUrl
                        metadata         = $properties.metadata
                        redirectUrl      = $WorkIqFixture.RedirectUrl
                    }
                }
                return ($State.Connection | ConvertTo-Json -Depth 6 -Compress)
            }
            'keyvault show*' { return ($State.Vault | ConvertTo-Json -Compress) }
            'keyvault network-rule add*' { $State.Vault.ipRules = @('203.0.113.7/32'); return '{}' }
            'keyvault network-rule remove*' { $State.Vault.ipRules = @(); return }
            'keyvault secret list*' { return '[]' }
            'keyvault secret set*' {
                $State.StoredText = [IO.File]::ReadAllText([string] $args[[array]::IndexOf($args, '--file') + 1])
                return '"https://kv-fixture.vault.azure.net/secrets/workiq-client-secret/version1"'
            }
            default { throw "Unexpected Azure call: $line" }
        }
    }

    function Invoke-RestMethod { return '203.0.113.7' }
    function Start-Sleep { }

    return @(& $WorkIqFixture.ConfigureScript @Arguments 6>&1) -join "`n"
}

function Get-CurrentConnection {
    return @{
        id         = "$($WorkIqFixture.ProjectId)/connections/workiq"
        properties = @{
            target           = 'https://workiq.svc.cloud.microsoft/a2a/'
            authorizationUrl = "https://login.microsoftonline.com/$($WorkIqFixture.TenantId)/oauth2/v2.0/authorize"
            redirectUrl      = $WorkIqFixture.RedirectUrl
            metadata         = @{
                ApiType               = 'Azure'
                WorkIqAppId           = $WorkIqFixture.AppId
                WorkIqSecretVersion   = 'version1'
                WorkIqSecretExpiresOn = [datetime]::UtcNow.AddDays(120).ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
        }
    }
}

Test-Case 'azd runs configure-workiq as the postprovision hook' {
    $azureYaml = Get-Content -LiteralPath (Get-RepoPath 'azure.yaml') -Raw
    Assert-Match -Actual $azureYaml -Pattern '(?ms)^  postprovision:.*?\./scripts/configure-workiq\.ps1' `
        -Message 'azure.yaml must run scripts/configure-workiq.ps1 after provisioning.'
}

Test-Case 'configure-workiq is a no-op when the Foundry project is not deployed' {
    $state = New-WorkIqState
    $state.Env.Remove('FOUNDRY_PROJECT_ID')
    $output = Invoke-ConfigureWorkIq -State $state

    Assert-Match -Actual $output -Pattern 'aiFoundry is not deployed' -Message 'The hook must say why it did nothing.'
    Assert-Equal -Actual $state.Calls.Count -Expected 0 -Message 'The hook must not call Azure when aiFoundry is off.'
}

Test-Case 'configure-workiq leaves a current connection and Key Vault alone' {
    $state = New-WorkIqState -Connection (Get-CurrentConnection) -AppRedirectUris @($WorkIqFixture.RedirectUrl)
    $output = Invoke-ConfigureWorkIq -State $state

    Assert-Match -Actual $output -Pattern 'is current' -Message 'A connection with matching markers must be kept.'
    foreach ($call in $state.Calls) {
        Assert-True -Condition (-not $call.StartsWith('keyvault')) -Message "The fast path must not touch Key Vault: $call"
        Assert-True -Condition (-not $call.StartsWith('rest --method put')) -Message 'The fast path must not recreate the connection.'
        Assert-True -Condition (-not $call.StartsWith('rest --method delete')) -Message 'The fast path must not delete the connection.'
    }
    Assert-Equal -Actual $state.Env.WORKIQ_REDIRECT_URI -Expected $WorkIqFixture.RedirectUrl `
        -Message 'The redirect URL must still be recorded in the azd environment.'
}

Test-Case 'configure-workiq replaces an unmanaged connection without exposing the secret' {
    # A connection created in the portal has no markers, so the script cannot
    # tell which secret it holds and must replace it.
    $unmanaged = Get-CurrentConnection
    $unmanaged.properties.metadata = @{ ApiType = 'Azure' }
    $state = New-WorkIqState -Connection $unmanaged -AppRedirectUris @('https://example.test/existing')
    $null = Invoke-ConfigureWorkIq -State $state

    # Secret handling.
    Assert-Equal -Actual $state.StoredText -Expected $WorkIqFixture.SecretText `
        -Message 'The new client secret must be stored in Key Vault exactly.'
    foreach ($call in $state.Calls) {
        Assert-True -Condition (-not $call.Contains($WorkIqFixture.SecretText)) `
            -Message "The client secret must never appear on a command line: $call"
    }
    foreach ($file in $state.Files) {
        Assert-True -Condition (-not (Test-Path -LiteralPath $file)) `
            -Message "Temporary file '$file' must be deleted."
    }

    # Firewall: opened for this machine only, then closed again.
    $add = $state.Calls.FindIndex({ param($c) $c.StartsWith('keyvault network-rule add') })
    $remove = $state.Calls.FindIndex({ param($c) $c.StartsWith('keyvault network-rule remove') })
    Assert-True -Condition ($add -ge 0) -Message 'The script must open the Key Vault firewall for this machine.'
    Assert-True -Condition ($remove -gt $add) -Message 'The temporary firewall rule must be removed.'
    Assert-Match -Actual $state.Calls[$add] -Pattern '203\.0\.113\.7/32' -Message 'The rule must be a single /32.'

    # Connection: deleted, then recreated with markers and the new credentials.
    $delete = $state.Calls.FindIndex({ param($c) $c.StartsWith('rest --method delete') })
    $put = $state.Calls.FindIndex({ param($c) $c.StartsWith('rest --method put') })
    Assert-True -Condition ($delete -ge 0 -and $put -gt $delete) -Message 'An immutable connection must be deleted before it is recreated.'
    Assert-Equal -Actual $state.PutBody.properties.category -Expected 'RemoteA2A' -Message 'Work IQ connections are RemoteA2A.'
    Assert-Equal -Actual $state.PutBody.properties.Credentials.ClientId -Expected $WorkIqFixture.AppId -Message 'The connection must use the bootstrap app.'
    Assert-Equal -Actual $state.PutBody.properties.metadata.WorkIqAppId -Expected $WorkIqFixture.AppId -Message 'The connection must carry its marker.'
    Assert-Match -Actual $state.PutBody.properties.TokenUrl -Pattern $WorkIqFixture.TenantId -Message 'The token URL must be tenant-specific.'

    # Superseded secrets and redirect URIs.
    Assert-True -Condition (@($state.Calls | Where-Object { $_ -like 'ad app credential delete*old-key*' }).Count -eq 1) `
        -Message 'The superseded client secret must be removed.'
    Assert-True -Condition ($state.Redirects -contains $WorkIqFixture.RedirectUrl) -Message 'The redirect URL must be added to the app.'
    Assert-True -Condition ($state.Redirects -contains 'https://example.test/existing') -Message 'Other redirect URIs must be kept.'
    Assert-Equal -Actual $state.Env.WORKIQ_REDIRECT_URI -Expected $WorkIqFixture.RedirectUrl -Message 'The redirect URL must be recorded.'
}

Test-Case 'configure-workiq never opens a private Key Vault' {
    $state = New-WorkIqState -VaultAccess 'Disabled'
    $null = Invoke-ConfigureWorkIq -State $state 3>$null

    Assert-True -Condition (@($state.Calls | Where-Object { $_ -like 'keyvault network-rule*' }).Count -eq 0) `
        -Message 'A vault with public access disabled must stay closed.'
}
