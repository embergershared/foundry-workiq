# maps

Azure Maps Gen2 account for search and routing, accessed with Microsoft Entra ID.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `map` |
| Providers | `Microsoft.Maps` |
| Private endpoints | – |
| Feature flag | `maps` |
| Name rule | `regional`, built with the location code of the Maps region |

## Purpose

An Azure Maps Gen2 account for search and routing. Callers authenticate with Entra ID and send `clientId` as the `x-ms-client-id` header. Azure Maps supports a limited set of regions, so the account often lives outside the workload region; build its name with that region's location code.

Set `disableLocalAuth` to `true` once no tool needs the account key.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes |  |
| `location` | string | no | A region Azure Maps supports, for example `eastus` |
| `tags` | object | no |  |
| `disableLocalAuth` | bool | no | Default `false` |
| `readerPrincipalIds` | array | no | Granted Azure Maps Data Reader |
| `readerPrincipalType` | string | no | Default `ServicePrincipal` |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `clientId` | Account client ID for `x-ms-client-id` |

## Wire-up

```bicep
module maps 'modules/maps/main.bicep' = {
  scope: resourceGroup
  name: 'maps'
  params: {
    name: azName(abbreviations.mapsAccount, tenantCode, locationCodeFor(mapsLocation), subscriptionCode, environmentName, '')
    location: mapsLocation
    tags: tags
  }
}
```
