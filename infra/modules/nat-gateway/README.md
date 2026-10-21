# nat-gateway

Standard NAT Gateway with a Standard public IP, for deterministic outbound
egress from the jumpbox subnet.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `full` |
| Abbreviation | `natgw` |
| Providers | `Microsoft.Network` |
| Private endpoint | none |
| Feature flag | `natGateway` |

## Purpose

Microsoft Entra login extensions on a virtual machine need outbound internet
access to reach Entra ID. Without egress the extension provisioning hangs and
then fails.

Because of that, `natGateway` and `entraLogin` must agree. An air-gapped
override must set **both** to `false`:

```json
{ "natGateway": false, "entraLogin": false }
```

`scripts/preflight.ps1` rejects a mismatched pair before any deployment starts.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | |
| `publicIpName` | string | yes | |
| `location` | string | no | Defaults to the resource group location |
| `tags` | object | no | |
| `enabled` | bool | no | Default `false`; when false nothing is deployed and outputs are empty |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output; empty string when `enabled` is false |
| `name` | Contract output; empty string when `enabled` is false |
| `natGatewayId` | Deprecated alias |
