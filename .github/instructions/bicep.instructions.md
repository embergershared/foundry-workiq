---
applyTo: "infra/**/*.bicep,infra/**/*.json"
---

# Bicep instructions

- Keep `infra/main.bicep` subscription-scoped and modules resource-group-scoped
  unless an approved architecture decision requires otherwise.
- Use current stable API versions, typed/validated parameters, deterministic
  names, existing abbreviations, explicit dependencies, and nonsensitive
  composition outputs.
- Preserve profile defaults and validate every override dependency in preflight
  before provisioning. Do not create success-shaped fallbacks.
- Use `@secure()` for secret parameters. Never output secrets, keys, credentials,
  connection strings, or private material. Prefer managed identity and RBAC.
- Keep Key Vault purge protection and template-deployment access, and keep
  Storage shared-key access disabled. Key Vault/Storage public access is disabled
  with private endpoints; the approved core-default design permits explicit
  public-capable opt-ins without a network, subject to per-environment exposure
  approval, RBAC and TLS. Catalog membership never enables a resource by itself.
- Add private endpoints together with correct zone groups, VNet-linked Private
  DNS, NSGs, diagnostics, and tests. Public access requires an explicit decision.
- Run Bicep format, lint, and build plus profile/invalid-combination validation.
