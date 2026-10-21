# managed-identity

User-assigned managed identity for workloads to reach Azure services without secrets.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `id` |
| Providers | `Microsoft.ManagedIdentity` |
| Private endpoints | – |
| Feature flag | `managedIdentity` |
| Name rule | `regional` |

## Purpose

A user-assigned identity for a workload. It outlives the workload, so role assignments made to it survive redeployments. Use the workload as the name suffix, for example `id-<base>-web`.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Use the workload as the suffix |
| `location` | string | no |  |
| `tags` | object | no |  |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `principalId` | For role assignments |
| `clientId` | Pass to the workload as `AZURE_CLIENT_ID` |

## Wire-up

```bicep
module identity 'modules/managed-identity/main.bicep' = {
  scope: resourceGroup
  name: 'managed-identity'
  params: {
    name: azName(abbreviations.managedIdentity, tenantCode, locationCode, subscriptionCode, environmentName, 'web')
    location: location
    tags: tags
  }
}
```
