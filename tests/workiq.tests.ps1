# Behaviour of scripts/configure-workiq.ps1, the azd postprovision hook that
# creates the Work IQ connection.
#
# az, azd and Start-Sleep are replaced with recording stubs, so the cases run
# offline and prove what the script sends where: in particular that the client
# secret never reaches a command line, that the vault is only ever reached
# through Azure Resource Manager, and that no URL carries the parentheses
# cmd.exe rejects on Windows.

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
    AppObjectId     = '44444444-4444-4444-4444-444444444444'
    Target          = 'https://workiq.svc.cloud.microsoft/a2a/'
    RedirectUrl     = 'https://global.consent.azure-apim.net/redirect/fixture-workiq'
    SecretText      = 'fixture-secret-' + [guid]::NewGuid().ToString('N')
}

function New-WorkIqState {
    <#
    .SYNOPSIS
        The mutable world the stubs read and write for one test case.
    #>
    param(
        [switch] $WithConnection,
        [AllowNull()] [string] $SecretClientId = $WorkIqFixture.AppId,
        [int] $SecretExpiresInDays = 200,
        [string[]] $AppRedirectUris = @()
    )

    $secret = $null
    if ($SecretClientId) {
        $secret = @{
            tags       = @{ clientId = $SecretClientId; connection = 'workiq' }
            properties = @{ attributes = @{ enabled = $true; exp = [DateTimeOffset]::UtcNow.AddDays($SecretExpiresInDays).ToUnixTimeSeconds() } }
        }
    }
    $connection = $null
    if ($WithConnection) {
        $connection = @{ properties = @{ target = $WorkIqFixture.Target; redirectUrl = $WorkIqFixture.RedirectUrl } }
    }

    return @{
        Env         = @{
            FOUNDRY_ACCOUNT_NAME  = 'aif-fixture'
            FOUNDRY_PROJECT_NAME  = 'proj-fixture'
            AZURE_RESOURCE_GROUP  = 'rg-fixture'
            AZURE_KEY_VAULT_NAME  = 'kv-fixture'
            AZURE_SUBSCRIPTION_ID = $WorkIqFixture.SubscriptionId
            AZURE_ENV_NAME        = 'fixture'
            WORKIQ_APP_ID         = $WorkIqFixture.AppId
        }
        Connection  = $connection
        Secret      = $secret
        Redirects   = $AppRedirectUris
        Calls       = [System.Collections.Generic.List[string]]::new()
        Files       = [System.Collections.Generic.List[string]]::new()
        SecretBody  = $null
        ConnectBody = $null
    }
}

function Invoke-ConfigureWorkIq {
    <#
    .SYNOPSIS
        Runs the real script against recording stubs and returns its output.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [hashtable] $Arguments = @{}
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
        $bodyFile = ''
        foreach ($argument in $args) {
            if ([string] $argument -like '@*') {
                $bodyFile = ([string] $argument).Substring(1)
                $State.Files.Add($bodyFile)
            }
        }

        switch -Wildcard ($line) {
            'account show --query id*' { return $WorkIqFixture.SubscriptionId }
            'account show --query tenantId*' { return "`"$($WorkIqFixture.TenantId)`"" }
            'rest --method get*/connections/*' {
                if (-not $State.Connection) { $global:LASTEXITCODE = 3; return 'ERROR: (ResourceNotFound) Not Found' }
                return ($State.Connection | ConvertTo-Json -Depth 6 -Compress)
            }
            'rest --method get*/secrets/*' {
                if (-not $State.Secret) { $global:LASTEXITCODE = 3; return 'ERROR: (SecretNotFound) Not Found' }
                return ($State.Secret | ConvertTo-Json -Depth 6 -Compress)
            }
            'rest --method delete*' { $State.Connection = $null; return }
            'rest --method put*/secrets/*' {
                $State.SecretBody = Get-Content -LiteralPath $bodyFile -Raw | ConvertFrom-Json -AsHashtable
                $State.Secret = @{ tags = $State.SecretBody.tags; properties = @{ attributes = $State.SecretBody.properties.attributes } }
                return '{}'
            }
            'rest --method put*/connections/*' {
                $State.ConnectBody = Get-Content -LiteralPath $bodyFile -Raw | ConvertFrom-Json -AsHashtable
                $State.Connection = @{ properties = @{ target = $State.ConnectBody.properties.target; redirectUrl = $WorkIqFixture.RedirectUrl } }
                return ($State.Connection | ConvertTo-Json -Depth 6 -Compress)
            }
            'rest --method patch*' {
                $State.Redirects = @((Get-Content -LiteralPath $bodyFile -Raw | ConvertFrom-Json).web.redirectUris)
                return
            }
            'ad app credential reset*' {
                return (@{ appId = $WorkIqFixture.AppId; password = $WorkIqFixture.SecretText } | ConvertTo-Json -Compress)
            }
            'ad app credential list*' {
                return (@(
                        @{ displayName = 'foundry-workiq-fixture'; keyId = 'old-key'; startDateTime = '2026-01-01T00:00:00Z' }
                        @{ displayName = 'foundry-workiq-fixture'; keyId = 'new-key'; startDateTime = '2026-10-21T00:00:00Z' }
                        @{ displayName = 'foundry-workiq-other'; keyId = 'other-key'; startDateTime = '2025-01-01T00:00:00Z' }
                    ) | ConvertTo-Json -Compress)
            }
            'ad app credential delete*' { return }
            'ad app show*' {
                return (@{ id = $WorkIqFixture.AppObjectId; redirectUris = @($State.Redirects) } | ConvertTo-Json -Compress)
            }
            default { throw "Unexpected Azure call: $line" }
        }
    }

    function Start-Sleep { }

    return @(& $WorkIqFixture.ConfigureScript @Arguments) -join "`n"
}

function Assert-NoSecretLeak {
    param([Parameter(Mandatory)] [hashtable] $State)

    foreach ($call in $State.Calls) {
        Assert-True -Condition (-not $call.Contains($WorkIqFixture.SecretText)) `
            -Message "The client secret must never appear on a command line: $call"
        Assert-True -Condition (-not $call.StartsWith('keyvault')) `
            -Message "The vault must only be reached through Resource Manager, never its data plane or firewall: $call"
        Assert-NotMatch -Actual $call -Pattern '--url \S*[()]' `
            -Message "On Windows cmd.exe rejects unquoted parentheses in a URL: $call"
    }
    foreach ($file in $State.Files) {
        Assert-True -Condition (-not (Test-Path -LiteralPath $file)) -Message "Temporary file '$file' must be deleted."
    }
}

Test-Case 'azd runs configure-workiq as the postprovision hook' {
    $azureYaml = Get-Content -LiteralPath (Get-RepoPath 'azure.yaml') -Raw
    Assert-Match -Actual $azureYaml -Pattern '(?ms)^  postprovision:.*?\./scripts/configure-workiq\.ps1' `
        -Message 'azure.yaml must run scripts/configure-workiq.ps1 after provisioning.'
}

Test-Case 'configure-workiq is a no-op when the Foundry account is not deployed' {
    $state = New-WorkIqState
    $state.Env.Remove('FOUNDRY_ACCOUNT_NAME')
    $output = Invoke-ConfigureWorkIq -State $state

    Assert-Match -Actual $output -Pattern 'aiFoundry is not deployed' -Message 'The hook must say why it did nothing.'
    Assert-Equal -Actual $state.Calls.Count -Expected 0 -Message 'The hook must not call Azure when aiFoundry is off.'
}

Test-Case 'configure-workiq keeps a current connection and its secret' {
    $state = New-WorkIqState -WithConnection -AppRedirectUris @($WorkIqFixture.RedirectUrl)
    $output = Invoke-ConfigureWorkIq -State $state

    Assert-Match -Actual $output -Pattern 'is current' -Message 'A current connection must be kept.'
    foreach ($verb in @('ad app credential reset', 'rest --method put', 'rest --method delete', 'rest --method patch')) {
        Assert-True -Condition (@($state.Calls | Where-Object { $_.StartsWith($verb) }).Count -eq 0) `
            -Message "The current path must not run '$verb'."
    }
    Assert-Equal -Actual $state.Env.WORKIQ_REDIRECT_URI -Expected $WorkIqFixture.RedirectUrl `
        -Message 'The redirect URL must still be recorded in the azd environment.'
    Assert-NoSecretLeak -State $state
}

Test-Case 'configure-workiq rotates a secret inside the renewal window' {
    $state = New-WorkIqState -WithConnection -SecretExpiresInDays 10 -AppRedirectUris @($WorkIqFixture.RedirectUrl)
    $output = Invoke-ConfigureWorkIq -State $state

    Assert-Match -Actual $output -Pattern 'renewal window' -Message 'The hook must say why it rotates.'
    $delete = $state.Calls.FindIndex({ param($c) $c.StartsWith('rest --method delete') })
    $put = $state.Calls.FindIndex({ param($c) $c -like 'rest --method put*/connections/*' })
    Assert-True -Condition ($delete -ge 0 -and $put -gt $delete) `
        -Message 'An expiring secret must replace the immutable connection.'
    Assert-NoSecretLeak -State $state
}

Test-Case 'configure-workiq replaces a connection whose secret it did not store' {
    # A connection created in the portal leaves no tagged secret in the vault.
    $state = New-WorkIqState -WithConnection -SecretClientId $null -AppRedirectUris @('https://example.test/existing')
    $null = Invoke-ConfigureWorkIq -State $state

    # Secret: written through Resource Manager, with an expiry and the app tag.
    Assert-Equal -Actual $state.SecretBody.properties.value -Expected $WorkIqFixture.SecretText `
        -Message 'The new client secret must be stored in Key Vault exactly.'
    Assert-Equal -Actual $state.SecretBody.tags.clientId -Expected $WorkIqFixture.AppId -Message 'The secret must be tagged with its app.'
    Assert-True -Condition ($state.SecretBody.properties.attributes.exp -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) `
        -Message 'The secret must carry a future expiry.'

    # Connection: deleted, then recreated with the article's body.
    $delete = $state.Calls.FindIndex({ param($c) $c.StartsWith('rest --method delete') })
    $put = $state.Calls.FindIndex({ param($c) $c -like 'rest --method put*/connections/*' })
    Assert-True -Condition ($delete -ge 0 -and $put -gt $delete) -Message 'An immutable connection must be deleted before it is recreated.'
    $properties = $state.ConnectBody.properties
    Assert-Equal -Actual $properties.category -Expected 'RemoteA2A' -Message 'Work IQ connections are RemoteA2A.'
    Assert-Equal -Actual $properties.Credentials.ClientId -Expected $WorkIqFixture.AppId -Message 'The connection must use the bootstrap app.'
    Assert-Equal -Actual $properties.Credentials.ClientSecret -Expected $WorkIqFixture.SecretText -Message 'The connection must use the new secret.'
    Assert-Match -Actual $properties.TokenUrl -Pattern $WorkIqFixture.TenantId -Message 'The token URL must be tenant-specific.'

    # Superseded secrets: only this environment's older one goes.
    $deleted = @($state.Calls | Where-Object { $_ -like 'ad app credential delete*' })
    Assert-Equal -Actual $deleted.Count -Expected 1 -Message 'Exactly one superseded secret must be removed.'
    Assert-Match -Actual $deleted[0] -Pattern 'old-key' -Message "This environment's older secret must be removed, not the new one or another environment's."

    # Redirect URIs: added, the others kept.
    Assert-True -Condition ($state.Redirects -contains $WorkIqFixture.RedirectUrl) -Message 'The redirect URL must be added to the app.'
    Assert-True -Condition ($state.Redirects -contains 'https://example.test/existing') -Message 'Other redirect URIs must be kept.'
    Assert-Equal -Actual $state.Env.WORKIQ_REDIRECT_URI -Expected $WorkIqFixture.RedirectUrl -Message 'The redirect URL must be recorded.'

    Assert-NoSecretLeak -State $state
}

Test-Case 'configure-workiq creates the connection when there is none' {
    $state = New-WorkIqState -SecretClientId $null
    $null = Invoke-ConfigureWorkIq -State $state

    Assert-True -Condition (@($state.Calls | Where-Object { $_.StartsWith('rest --method delete') }).Count -eq 0) `
        -Message 'There is nothing to delete when no connection exists.'
    Assert-True -Condition ($null -ne $state.ConnectBody) -Message 'The connection must be created.'
    Assert-NoSecretLeak -State $state
}
