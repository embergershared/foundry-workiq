# Module-specific assertions for 'managed-redis'.
#
# The uniform contract (params, outputs, metadata schema, catalog sync, build
# and lint) is already covered by tests/catalog.tests.ps1 and tests/bicep.tests.ps1.
# Add assertions here only for behaviour unique to this module.

. (Join-Path $PSScriptRoot '..' 'assert.ps1')
. (Join-Path $PSScriptRoot '..' 'common.ps1')

Test-Case 'managed-redis creates the database the way RediSearch requires' {
    $bicep = Get-Content -LiteralPath (Get-RepoPath 'infra/modules/managed-redis/main.bicep') -Raw
    Assert-NotMatch -Actual $bicep -Pattern 'TODO' `
        -Message 'The scaffolded placeholders must be replaced before the module ships.'

    # Modules and the clustering policy can't change after the database is
    # created, so these values are fixed rather than parameters.
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/modules/managed-redis/main.bicep')
    $cluster = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Cache/redisEnterprise' })[0]
    $databaseResource = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Cache/redisEnterprise/databases' })[0]
    $database = $databaseResource.properties
    Assert-True -Condition (@($database.modules | Where-Object { $_.name -eq 'RediSearch' }).Count -eq 1) `
        -Message 'Semantic caching needs the RediSearch module.'
    Assert-Equal -Actual $database.clusteringPolicy -Expected 'EnterpriseCluster' -Message 'RediSearch requires the Enterprise clustering policy.'
    Assert-Equal -Actual $database.evictionPolicy -Expected 'NoEviction' -Message 'RediSearch requires the NoEviction eviction policy.'
    Assert-Equal -Actual $database.clientProtocol -Expected 'Encrypted' -Message 'Clients must connect over TLS.'
    Assert-Equal -Actual $database.accessKeysAuthentication -Expected 'Enabled' `
        -Message 'API Management connects to Azure Managed Redis only with an access key.'
    Assert-Equal -Actual $cluster.properties.minimumTlsVersion -Expected '1.2' -Message 'TLS 1.2 is the minimum.'
    Assert-Match -Actual ([string] $databaseResource.name) -Pattern "'default'" `
        -Message "API Management and the portal expect the database to be named 'default'."
}

Test-Case 'managed-redis offers only SKUs that support RediSearch' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/modules/managed-redis/main.bicep')
    $skus = @($template.parameters.sku.allowedValues)
    Assert-True -Condition ($skus.Count -gt 0) -Message 'The module must restrict its SKUs.'
    Assert-True -Condition (@($skus | Where-Object { $_ -notmatch '^(Balanced|MemoryOptimized|ComputeOptimized)_' }).Count -eq 0) `
        -Message 'Flash Optimized does not support RediSearch, so only in-memory tiers are allowed.'
    Assert-Equal -Actual $template.parameters.sku.defaultValue -Expected 'Balanced_B0' -Message 'Balanced B0 must stay the default SKU.'
}

Test-Case 'the gateway reads the Redis key at deployment time and never outputs it' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/modules/api-management/main.bicep')
    $cache = $template.resources.externalCache
    Assert-True -Condition ($null -ne $cache) -Message "api-management must declare the 'externalCache' resource."
    Assert-Equal -Actual $cache.properties.useFromLocation -Expected 'default' `
        -Message 'The semantic caching policies use the default external cache.'
    Assert-Match -Actual ([string] $cache.properties.connectionString) -Pattern 'listKeys' `
        -Message 'The connection string must read the key with listKeys(), never from a parameter.'
    Assert-Match -Actual ([string] $cache.properties.connectionString) -Pattern 'ssl=True' -Message 'The gateway must connect over TLS.'

    foreach ($output in $template.outputs.PSObject.Properties) {
        Assert-NotMatch -Actual ([string] $output.Value.value) -Pattern 'listKeys|password' `
            -Message "Output '$($output.Name)' must not expose the Redis key."
    }
    foreach ($parameter in $template.parameters.PSObject.Properties) {
        Assert-NotMatch -Actual $parameter.Name -Pattern '(?i)key|password|connectionString' `
            -Message "Parameter '$($parameter.Name)' must not carry the Redis key."
    }
}
