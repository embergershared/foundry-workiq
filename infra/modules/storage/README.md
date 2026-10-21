# storage

StorageV2 account with TLS 1.2, no shared key access and no public blob access.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `stacct` |
| Providers | `Microsoft.Storage` |
| Private endpoints | `blob` -> `privatelink.blob.core.windows.net`, `file` -> `privatelink.file.core.windows.net` |
| Feature flag | `storage` |
| Name rule | `globalCompact` (24 characters, lowercase alphanumeric only) |

## Purpose

An opt-in general purpose storage account. Two private endpoints, because blob
and file are separate Azure private link group IDs with separate DNS zones.

Supplying a subnet plus the matching zone IDs switches the account to
private-only. Leaving them empty leaves it public with a deny-by-default
firewall that still trusts Azure services.

Each endpoint is independent: you may wire only `blob` and leave `file` public.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Must satisfy the `globalCompact` name rule |
| `location` | string | no | Defaults to the resource group location |
| `tags` | object | no | |
| `blobPrivateEndpointName` | string | yes | Ignored when no subnet is supplied |
| `blobPrivateEndpointNetworkInterfaceName` | string | yes | |
| `filePrivateEndpointName` | string | yes | |
| `filePrivateEndpointNetworkInterfaceName` | string | yes | |
| `privateEndpointSubnetId` | string | no | Empty means public with firewall |
| `blobPrivateDnsZoneId` | string | no | |
| `filePrivateDnsZoneId` | string | no | |
| `logAnalyticsWorkspaceId` | string | yes | Diagnostics target |
| `enableRoleAssignments` | bool | no | Default `true` |
| `operatorPrincipalIds` | array | no | Granted blob and file data roles |
| `blobContainerNames` | array | no | Private blob containers to create |
| `deleteBlobsAfterDays` | int | no | Lifecycle deletion of blobs in those containers after N days since last modification; `0` (default) disables it |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `storageAccountId` / `storageAccountName` | Deprecated aliases |

## Wire-up

```bicep
module storage 'modules/storage/main.bicep' = if (deployStorage) {
  scope: resourceGroup
  name: 'storage'
  params: {
    name: storageAccountName
    blobPrivateEndpointName: storageBlobPrivateEndpointName
    blobPrivateEndpointNetworkInterfaceName: storageBlobPrivateEndpointNicName
    filePrivateEndpointName: storageFilePrivateEndpointName
    filePrivateEndpointNetworkInterfaceName: storageFilePrivateEndpointNicName
    privateEndpointSubnetId: deployNetwork ? network!.outputs.privateEndpointSubnetId : ''
    blobPrivateDnsZoneId: deployNetwork ? privateDns!.outputs.blobZoneId : ''
    filePrivateDnsZoneId: deployNetwork ? privateDns!.outputs.fileZoneId : ''
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    location: location
    tags: tags
  }
}
```
