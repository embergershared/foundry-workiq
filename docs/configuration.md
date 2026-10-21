# Configuration

Configuration belongs in the selected `azd` environment, not committed files.
Use `azd env set`; never commit `.azure/<environment>`, `.env*`, credentials, or
generated deployment output.

## Profiles

Profiles are a cumulative ladder. Each rung deploys everything below it.

| Feature | `core` | `private` | `full` |
|---|:---:|:---:|:---:|
| Resource group and common tags | ✓ | ✓ | ✓ |
| Log Analytics and App Insights | ✓ | ✓ | ✓ |
| VNet, NSGs, private DNS |  | ✓ | ✓ |
| Private Key Vault and Storage |  | ✓ | ✓ |
| Windows and Ubuntu jumpboxes |  |  | ✓ |
| Standard Bastion |  |  | ✓ |
| NAT and Entra VM login |  |  | ✓ |
| VM auto-shutdown |  |  | ✓ |

```powershell
azd env set DEPLOYMENT_PROFILE core # core, private, or full
```

`core` is the default. It does not force Key Vault or Storage on a project —
those are [catalog modules](modules.md) a project opts into, and in `core` they
deploy public-with-firewall because there is no private endpoint subnet.

`minimal` is accepted as a deprecated alias for `private`. Preflight emits a
warning and resolves it to `private`; update the environment with
`azd env set DEPLOYMENT_PROFILE private`.

Moving down the ladder stops deploying disabled resources. ARM incremental
deployments can retain previously deployed resources, which may continue billing.
Always inspect `azd provision --preview` before a profile change. Cleanup requires
separate explicit approval and review of data retention, identities, dependencies,
and rollback/recovery; changing profiles does not guarantee deletion.

## Required environment values

| Name | Purpose | Required in |
|---|---|---|
| `AZURE_ENV_NAME` | Lowercase 2–32 character environment name; initialized by `azd env new` | all profiles |
| `AZURE_SUBSCRIPTION_ID` | Target subscription GUID; defaults to the active Azure CLI subscription and must match it | all profiles |
| `AZURE_SUBSCRIPTION_CODE` | Internal cached `s<N>` code initialized and verified by `set-deployment-tags.ps1` | all profiles |
| `AZURE_LOCATION` | Azure region, default design target `eastus2` | all profiles |
| `DEPLOYMENT_PROFILE` | `core`, `private`, or `full`; hook defaults to `core` | all profiles |
| `AZURE_REPOSITORY` | Repository name used for the `repository` tag; derived from the git remote by `set-deployment-tags.ps1` | all profiles |
| `AZURE_OPERATOR_PRINCIPAL_IDS` | Comma-separated Entra user/group object IDs | when a VM or role assignments are enabled |
| `AZURE_FEATURE_OVERRIDES_JSON` | Expert feature object; hook defaults to `{}` | optional |

`AZURE_OPERATOR_PRINCIPAL_IDS` is only required when the deployment grants VM
sign-in or data-plane roles — that is, the `full` profile or an override that
enables a VM or `roleAssignments`. A `core` or `private` deployment passes
preflight without it.

The hook base64-encodes override JSON into the internal
`AZURE_FEATURE_OVERRIDES_BASE64` transport value so AZD can substitute it into
ARM parameter JSON without quote corruption. Do not edit the encoded value.

`AZURE_REPOSITORY` is derived from the `origin` git remote, falling back to the
repository folder name. Set it explicitly when the tag should not match either —
for example when the same infrastructure is maintained in a fork.

When `AZURE_SUBSCRIPTION_ID` is not set, the environment helper initializes it
from the subscription the Azure CLI is signed in to (`az account show`). The
helper and preflight both fail when the Azure CLI's active subscription differs
from `AZURE_SUBSCRIPTION_ID`, because preflight queries Azure through the Azure
CLI while `azd` deploys with its own login. Fix it with
`az account set --subscription <AZURE_SUBSCRIPTION_ID>`.

The environment helper derives `AZURE_SUBSCRIPTION_CODE` from the active
subscription display name, seeds it with `AZURE_CREATED_ON`, and verifies it on
later runs. A final hyphen-delimited 1-4 digit token wins
(`Contoso-Projects-3` derives `s3`), then a delimited `s<N>` token
(`Contoso-s2-Sandbox` derives `s2`), then `s` plus the first four hex
characters of the subscription ID. For a display name that carries no code you
can instead choose one with `azd env set AZURE_SUBSCRIPTION_CODE s1` before the
first provision. If a
subscription rename would derive a different code, preflight fails instead of
silently changing resource identities. Review the replacement impact before
manually updating the cached code.

The pre-provision hook refreshes `AZURE_LAST_UPDATED_ON` on each provision
using America/New_York time with an explicit UTC offset. Do not edit these
lifecycle values casually.

After `azd env new` and the required `azd env set` commands, initialize the
first-use values once:

```powershell
.\scripts\set-deployment-tags.ps1
```

AZD resolves required Bicep inputs before it invokes `preprovision`, so the
first preview cannot rely on the hook to create them. Later provisions invoke
the same script automatically and preserve `AZURE_CREATED_ON`.

## Preflight validation

`scripts/preflight.ps1` runs automatically as the `preprovision` hook and fails
closed. It is tiered so a `core` deployment is not blocked by checks that do not
apply to it.

Core checks always run:

- `AZURE_ENV_NAME` format
- subscription GUID format, and that the subscription exists and is enabled
- the Azure CLI's active subscription matches `AZURE_SUBSCRIPTION_ID`
- `AZURE_SUBSCRIPTION_CODE` derivation and stability
- the subscription's tenant has an approved code in `infra/core/tenant-codes.json`
- the location is a recognized Azure region and is present in the location-code
  catalog

Conditional checks run only when the relevant feature is enabled:

| Check | Runs when |
|---|---|
| Resource provider registration | derived from the `providers` declared by the modules the profile enables |
| VM SKU availability, Windows image URN, vCPU quota | a jumpbox VM is enabled |
| Operator principal IDs present and well-formed | a VM or `roleAssignments` is enabled |
| Feature dependency rules | an expert override is set |

A `core` deployment therefore performs no `Microsoft.Network` or
`Microsoft.Compute` calls at all.

## Expert feature overrides

Supported Boolean keys are `network`, `keyVault`, `storage`, `bastion`,
`windowsVm`, `linuxVm`, `natGateway`, `entraLogin`, `shutdownSchedules`, and
`roleAssignments`.

```powershell
azd env set AZURE_FEATURE_OVERRIDES_JSON '{"keyVault":true,"storage":true}'
```

An override composes on top of the selected profile, so the example above adds a
public-with-firewall Key Vault and Storage account to a `core` deployment
without creating a network.

Dependency rules fail preflight:

- `shutdownSchedules` and `entraLogin` each require at least one VM.
- `natGateway` and `entraLogin` must have identical values.
- Any enabled jumpbox VM requires Bastion because the template has no VPN,
  peering, or VM public-IP access path.
- Enabling Bastion or a VM implies the network: the template derives
  `deployNetwork` from them, so you never have to enable `network` by hand.
- Full-profile Entra extension installation and authentication require NAT
  egress. Do not disable NAT alone.
- An expert air-gapped deployment **must** set both to false:

```powershell
azd env set AZURE_FEATURE_OVERRIDES_JSON '{"natGateway":false,"entraLogin":false}'
```

Air-gapped mode removes the primary Entra login path. Confirm an approved local
break-glass access process and required offline package/update strategy before
deployment.

Setting `roleAssignments` to `false` supports a deployer without
`roleAssignments/write`, but an authorized administrator must manually grant
the [operator roles](deployment.md#prerequisites-and-roles).

## Bicep-level parameters

`infra/main.bicep` also defines CIDRs, VM sizes and fixed image contracts,
retention (30–730 days), daily ingestion cap (minimum 1 GB), shutdown time,
Windows MDM application ID, and tag values. The current `azd` parameter file
exposes only the environment values above. To make another value reusable
through `azd`, update the Bicep parameter, `infra/main.parameters.json`,
preflight validation, and this document together.

The Windows contract is Windows 11 Pro 24H2 Gen2 and intentionally does not fall
back to Windows Server or Enterprise.

`windowsMdmId` defaults to an explicit empty string. This satisfies the
case-sensitive `AADLoginForWindows` extension contract without requesting
automatic MDM enrollment. Set it to the application ID of an approved MDM
provider only when that enrollment is intentional; Microsoft Intune uses
`0000000a-0000-0000-c000-000000000000`.

## Resource naming

The template enforces the
`<resource-prefix>-<tenant-code>-<location-code>-<subscription-code>-<environment>` order and
resource-specific length/character constraints in `infra/core/naming.bicep`; see
the [architecture naming contract](architecture.md#naming-contract). Do not
encode custom resource names in AZD environment values. Changing a prefix or
suffix replaces resources whose Azure names are immutable, so review the preview
for data migration, retained resources, downtime, and additional cost before
provisioning an existing environment.

`infra/core/tenant-codes.json` maps each Entra tenant ID to a display name and a
short code. A repository created from the template starts from
`tenant-codes.example.json`, whose only entry is a placeholder. Preflight fails
closed for a tenant that is not listed. Add a tenant before its first
deployment, and record it in [`docs/targets.md`](targets.md):

```json
"<tenant-guid>": { "name": "Contoso", "code": "123456" }
```

Changing an existing tenant's code renames, and therefore replaces, every
regional resource in that tenant. Each resource also gets a `tenant-code` tag.

`infra/core/location-codes.json` is the shared public-cloud location catalog
used by Bicep and preflight. An Azure location that is valid but not yet mapped
fails closed until the catalog receives a reviewed, unique country-first code.
