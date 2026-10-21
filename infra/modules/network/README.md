# network

The `/22` virtual network, its three subnets and their network security groups.

| | |
|---|---|
| Kind | `composite` |
| Profiles | `private`, `full` |
| Abbreviation | `vnet` |
| Providers | `Microsoft.Network` |
| Private endpoint | none — this module *hosts* private endpoints |
| Feature flag | `network` |

## Purpose

Establishes the private perimeter. Not deployed in the `core` profile.

Subnets:

| Subnet | Purpose | NSG posture |
|---|---|---|
| `AzureBastionSubnet` | Azure Bastion. The name is mandated by Azure and must never be renamed. | Bastion-required rules only |
| jumpbox subnet | Developer desktops | Deny-by-default inbound |
| private endpoint subnet | Every module private endpoint | Deny-by-default inbound |
| container apps subnet (optional) | Container Apps environment infrastructure, delegated to `Microsoft.App/environments` | Azure default rules; the environment manages its own ingress |

When `enableNatGateway` is true the jumpbox subnet is associated with the
supplied NAT Gateway for deterministic egress.

Set `deployJumpboxSubnets` to `false` for a workload without Bastion or
jumpboxes; `AzureBastionSubnet`, the jumpbox subnet and their NSGs are then
skipped (their name and prefix parameters are still required but unused).

A non-empty `containerAppsSubnetPrefix` adds the delegated Container Apps
subnet (`/27` or larger) with its own NSG. Owning that NSG keeps
subscription policies from attaching auto-generated NSGs whose names fall
outside the convention.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Virtual network name |
| `bastionNetworkSecurityGroupName` | string | yes | |
| `jumpboxNetworkSecurityGroupName` | string | yes | |
| `privateEndpointNetworkSecurityGroupName` | string | yes | |
| `jumpboxSubnetName` | string | yes | |
| `privateEndpointSubnetName` | string | yes | |
| `location` | string | no | |
| `tags` | object | no | |
| `vnetAddressPrefix` | string | yes | |
| `bastionSubnetPrefix` | string | yes | |
| `jumpboxSubnetPrefix` | string | yes | |
| `privateEndpointSubnetPrefix` | string | yes | |
| `enableNatGateway` | bool | no | Default `false` |
| `natGatewayId` | string | no | Required when `enableNatGateway` is true |
| `deployJumpboxSubnets` | bool | no | Default `true` |
| `containerAppsSubnetPrefix` | string | no | Empty (default) skips the Container Apps subnet |
| `containerAppsSubnetName` | string | no | Required with `containerAppsSubnetPrefix` |
| `containerAppsNetworkSecurityGroupName` | string | no | Required with `containerAppsSubnetPrefix` |

## Outputs

| Name | Notes |
|---|---|
| `virtualNetworkId` | Feed to `private-dns` for zone links |
| `virtualNetworkName` | |
| `bastionSubnetId` | |
| `jumpboxSubnetId` | |
| `privateEndpointSubnetId` | Feed to every private-endpoint-capable module |
| `containerAppsSubnetId` | Empty when the subnet is not deployed |
