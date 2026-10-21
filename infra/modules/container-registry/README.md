# container-registry

Azure Container Registry with admin user and anonymous pull disabled; images are pulled with managed identity.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `cr` |
| Providers | `Microsoft.ContainerRegistry` |
| Private endpoints | – |
| Feature flag | `containerRegistry` |
| Name rule | `globalCompact` (5-50 characters, lowercase alphanumeric only) |

## Purpose

A registry for workload images. The admin user is disabled; workloads pull with a managed identity granted `AcrPull` (pass its principal ID in `pullPrincipalIds`) and operators push with Entra ID, for example through `azd deploy` remote builds.

Public network access stays enabled: ACR Tasks remote builds need it, and private endpoints require the Premium SKU.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Must satisfy the `globalCompact` rule; use a 50-character budget |
| `location` | string | no | Defaults to the resource group location |
| `tags` | object | no |  |
| `sku` | string | no | `Basic` (default), `Standard` or `Premium` |
| `pullPrincipalIds` | array | no | Service principals granted `AcrPull` |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `loginServer` | For example `cruse2s3dev123.azurecr.io` |

## Wire-up

```bicep
module containerRegistry 'modules/container-registry/main.bicep' = {
  scope: resourceGroup
  name: 'container-registry'
  params: {
    name: globalName(abbreviations.containerRegistry, locationCode, subscriptionCode, environmentName, shortUniqueSuffix, '', 50)
    location: location
    tags: tags
    pullPrincipalIds: [ identity.outputs.principalId ]
  }
}
```
