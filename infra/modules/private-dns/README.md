# private-dns

Private DNS zones and their virtual network links, one per catalog module that
declares a private endpoint.

| | |
|---|---|
| Kind | `composite` |
| Profiles | `private`, `full` |
| Providers | `Microsoft.Network` |
| Feature flag | `network` |

## Purpose

Resolves private link records inside the virtual network. Not deployed in the
`core` profile because there are no private endpoints to resolve.

## Generated, not hand-edited

The zone list lives in `infra/core/private-dns-zones.json`, which is generated
by `scripts/build-catalog.ps1` from the `privateEndpoints` block of every
module `metadata.json`. Adding a private endpoint to a new module and
regenerating the catalog is all that is required — this module never needs a
manual edit.

Virtual network link names are derived as `<name>-<linkSuffix>-link` and are
part of the deployed resource identity. Changing a `linkSuffix` in metadata
replaces the link, so a test asserts the existing suffixes stay pinned.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Prefix for the virtual network link names |
| `location` | string | no | Always `global` for private DNS zones |
| `tags` | object | no | |
| `virtualNetworkId` | string | yes | The network to link every zone to |

## Outputs

| Name | Notes |
|---|---|
| `zones` | Array of `{ key, name, id }`, one entry per generated zone |
| `keyVaultZoneId` | Convenience output resolved from `zones` |
| `blobZoneId` | Convenience output resolved from `zones` |
| `fileZoneId` | Convenience output resolved from `zones` |
