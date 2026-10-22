# managed-redis

Azure Managed Redis cluster with the RediSearch module, used as the external cache that API Management needs for LLM semantic caching.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `full`, `private` |
| Abbreviation | `amr` |
| Providers | `Microsoft.Cache` |
| Private endpoint | none |
| Feature flag | `managedRedis` |
| Name rule | `global` |

## Purpose

[Semantic caching in API Management](https://learn.microsoft.com/azure/api-management/azure-openai-enable-semantic-caching)
returns a cached LLM response for a prompt that is close in meaning to an
earlier one. The `llm-semantic-cache-lookup` and `llm-semantic-cache-store`
policies need an external Redis cache with the **RediSearch** module, which
stores and searches the prompt embeddings. The API Management built-in cache
can't do it.

This module deploys an [Azure Managed Redis](https://learn.microsoft.com/azure/redis/overview)
cluster (`Microsoft.Cache/redisEnterprise`, the successor of the Azure Cache
for Redis Enterprise tier) with one database, `default`, set up the way
RediSearch requires:

| Database setting | Value | Why |
|---|---|---|
| Modules | `RediSearch` | Vector search over prompt embeddings |
| Clustering policy | `EnterpriseCluster` | Required by RediSearch |
| Eviction policy | `NoEviction` | Required by RediSearch; writes fail instead of evicting when memory is full, so size the SKU with headroom |
| Client protocol | `Encrypted`, port `10000`, TLS 1.2 | |
| Access keys | `Enabled` | API Management connects only with an access-key connection string; Microsoft Entra isn't supported for this connection |

Redis fixes the modules and the clustering policy when the database is
created. They can't be added or changed later, so the module doesn't expose
them as parameters, and preflight stops when an existing cluster for the
environment doesn't have them.

## Using it from API Management

With `apiManagement` on, `infra/main.bicep` passes the cluster to the
`api-management` module as `externalRedisName`. That module creates the
external cache entry `default` (**Use from: Default**), with a connection
string read by `listKeys()` during the deployment. API Management stores it as
a secret named value; the key is never a template parameter or output. To
rotate the key, regenerate it on the cluster and run `azd provision` again.

Semantic caching also needs, outside this template:

1. An embeddings model deployment, such as `text-embedding-3-small`, and an
   API Management backend for it that authenticates with the instance's
   managed identity.
2. The policies on each LLM API, for example:

   ```xml
   <inbound>
       <base />
       <llm-semantic-cache-lookup score-threshold="0.05"
           embeddings-backend-id="embeddings-backend"
           embeddings-backend-auth="system-assigned">
           <vary-by>@(context.Subscription.Id)</vary-by>
       </llm-semantic-cache-lookup>
   </inbound>
   <outbound>
       <llm-semantic-cache-store duration="300" />
       <base />
   </outbound>
   ```

   Keep `vary-by`: it stops one caller's cached answer from being returned to
   another.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Also the `<name>.<region>.redis.azure.net` host name, so it must be globally unique |
| `location` | string | no | Defaults to the resource group location; keep it with the API Management instance |
| `tags` | object | no | |
| `sku` | string | no | `Balanced_B0` (default) or another Balanced, Memory Optimized or Compute Optimized SKU; Flash Optimized doesn't support RediSearch |
| `highAvailability` | string | no | `Enabled` (default) or `Disabled`; required for the SLA, and can't be disabled once enabled |
| `logAnalyticsWorkspaceId` | string | no | Sends cluster metrics and database connection events to resource-specific tables |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `hostName` | `<name>.<region>.redis.azure.net` |
| `port` | TLS port of the `default` database (`10000`) |

## Wire-up

`infra/main.bicep` deploys it behind the `managedRedis` feature flag, in the
API Management region:

```bicep
module managedRedis './modules/managed-redis/main.bicep' = if (deployManagedRedis) {
  name: 'managed-redis'
  scope: resourceGroup
  params: {
    name: managedRedisName
    location: managedRedisLocation
    tags: tags
    sku: managedRedisSku
    highAvailability: managedRedisHighAvailability
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}
```

Set it per environment:

```powershell
azd env set AZURE_FEATURE_OVERRIDES_JSON '{"aiFoundry":true,"apiManagement":true,"managedRedis":true}'
azd env set AZURE_REDIS_SKU Balanced_B0                 # optional
azd env set AZURE_REDIS_HIGH_AVAILABILITY Enabled       # optional
```
