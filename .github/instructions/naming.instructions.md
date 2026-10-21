---
applyTo: "infra/**,azure.yaml,docs/**/*.md,scripts/**/*.ps1"
---

# Naming and tagging instructions

- Compose names with the exported functions in `infra/core/naming.bicep`
  (`baseName`, `azName`, `globalName`). Never reimplement the algorithm in a
  module or in `infra/main.bicep`; a second copy is how conventions drift.
- Reuse `infra/core/abbreviations.json` and established Azure Cloud Adoption
  Framework abbreviations; do not invent competing prefixes. A new catalog
  module must declare an abbreviation that already exists in that file.
- Derive deterministic uniqueness from subscription, environment, and region.
  Enforce each resource's character, case, global uniqueness, and length rules
  as recorded in `infra/core/name-rules.json`.
- Compose configurable names in
  `<resource-prefix>-<tenant-code>-<location-code>-<subscription-code>-<environment>`
  order. Resolve the tenant code from `infra/core/tenant-codes.json` by tenant
  ID (2-12 lowercase alphanumeric characters, empty for pre-tenant names); only
  regional names carry it, never Key Vault or storage names.
  Use the shared `infra/core/location-codes.json` catalog and cached
  subscription code. The code is `s<N>` from a `-<1-4 digits>` display-name
  suffix or a delimited `s<N>` name token (`Contoso-s2-Projects`), otherwise `s`
  plus the first four hex characters of the subscription ID, unless
  `AZURE_SUBSCRIPTION_CODE` is explicitly set for a name that carries no code;
  fail closed when either derivation is invalid or unstable.
- Use the repository naming contract:
  `rg-`, `appins-`, `law-`, `pe-`, `pe-nic-`, `vnet-`, `snet-`, `nsg-`,
  `bast-`, `vm-win-`, `vm-lin-`, `stacct`, `kv-`, `cae-`, `ca-`, `cr`, `id-`,
  `aif-`, `proj-`, and `map-`. Storage account and container registry names
  must contain only lowercase letters and numbers.
- Name every platform-managed resource group with
  `managedResourceGroupName(resourceGroupName)`: the full name of the resource
  group that owns the service plus `-managed`, for example
  `rg-123456-use2-s3-dev-managed`. This covers the Container Apps environment
  `infrastructureResourceGroup`, the AKS `nodeResourceGroup`, managed
  application and Databricks managed resource groups, and any other service
  that creates its own resource group. Never accept the generated `MC_`/`ME_`
  names, and never put workload resources in a managed resource group. These
  names are set at creation and cannot change without recreating the service.
- Prefix subnets with `snet-` except for service-reserved names. Azure Bastion
  must use the exact subnet name `AzureBastionSubnet`.
- Use a stable three-character suffix derived from subscription, environment,
  and region only for globally unique resources with short name limits.
  Truncate only the environment segment after reserving required fixed
  segments. Do not use nondeterministic names that change during repeat
  deployments.
- Keep `AZURE_ENV_NAME` lowercase, 2–32 characters, alphanumeric/hyphen, starting
  and ending alphanumeric. Do not embed a tenant, subscription, user, email, or
  secret in a resource name.
- Preserve common tags, which come from the exported `commonTags` function in
  `infra/core/tags.bicep`: repository, `azd-env-name`, environment, profile,
  `managed-by`, `created-on`, and `last-updated-on`. Use non-PII team/service
  values for optional owner and cost-center tags. The repository tag is derived
  from the git remote, never hard-coded in Bicep.
- A module whose names are dictated by the service — such as private DNS
  zones — declares `"nameRule": "fixed"` in its `metadata.json` and is exempt
  from the prefix contract. Every other module must map to one of the rules in
  `infra/core/name-rules.json`.
- Treat names as stable contracts. Renames that replace resources require an
  explicit migration, cost, data-retention, and rollback review. `tests/` renders
  the full name set from the compiled template and fails on any drift, so a
  rename is a deliberate, reviewed baseline update — not an accident.
