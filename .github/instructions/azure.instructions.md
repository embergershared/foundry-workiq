---
applyTo: "azure.yaml,.azure/**/*.md,scripts/**/*.ps1,docs/**/*.md,README.md"
---

# Azure and azd instructions

- Treat `.azure/deployment-plan.md` as deployment source of truth and keep it
  aligned with `README.md`, `docs/`, `azure.yaml`, hooks, and Bicep.
- Preserve the `azure-prepare → azure-validate → azure-deploy` gates. Before a
  cloud change, verify environment, tenant, subscription, location, policy,
  providers, quota, RBAC, licensing, preview, and approval.
- Use `azd` for lifecycle operations and modular Bicep under `infra/`. Never
  report success without post-deployment resource and endpoint checks.
- Keep values environment-driven. Never read live `.env*`, commit `.azure`
  environment state, or expose secrets through commands, logs, docs, outputs,
  or parameters that are not secure.
- Preserve private-by-default networking and documented public exceptions.
  Full-profile Entra login requires NAT; air-gapped mode disables both.
- Prefer managed identity, Entra ID, built-in least-privilege roles, private
  endpoints, TLS, diagnostic settings, and explicit deny/default-off behavior.
