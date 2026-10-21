# Work IQ on Foundry: automated deployment plan

Status: **Phases 0 and 1 are implemented, not yet deployed to a tenant.
Phases 2 to 4 are still a plan.**

Source: [Connect agents to Microsoft 365 with Work IQ (preview), .NET pivot](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/work-iq?pivots=dotnet),
plus the [Work IQ A2A quickstart](https://learn.microsoft.com/microsoft-365/copilot/extensibility/work-iq-api-quickstart)
and [Enable your tenant for Work IQ](https://learn.microsoft.com/microsoft-365/copilot/extensibility/work-iq/enable-work-iq).
Reviewed 2026-10-21. Work IQ is in preview, so recheck these pages before you
implement the plan.

## Goal

A single `azd up` (after a one-time tenant bootstrap) produces a working
Foundry project with a Work IQ connection and a .NET prompt agent that answers
questions grounded in the signed-in user's Microsoft 365 data. The portal is
used only where Microsoft provides no API.

**No Foundry toolbox.** The article recommends one, but this project attaches
`WorkIQPreviewTool` directly to a prompt agent (the article's .NET "Prompt
agents" path). That rules out `WorkIQPreviewToolboxTool`, the toolbox MCP
endpoint, the `remote-tool` connection that points at it, and hosted agents,
because the article connects hosted agents to Work IQ only through a toolbox.

## What the article requires, and how each piece is automated

| # | Requirement from the article | Owner / privilege | Automation | Portal needed? |
|---|---|---|---|---|
| 1 | Copilot Credits usage-based billing enabled, calling users in a spending policy that includes Work IQ API | Global or Billing Admin (M365) | None documented | **Yes, once per tenant** (M365 admin center → Copilot → Cost Management) |
| 2 | Work IQ service principal (`appId fdcc1f02-fc51-4226-8753-f668596af7f7`) exists in the tenant | Global Admin (PIM, just in time) | `az ad sp create --id fdcc1f02-…` in `scripts/bootstrap-tenant.ps1`, idempotent (a conflict means it already exists) | No |
| 3 | Foundry account (AIServices) + project + model deployment | Azure Contributor | Existing `infra/modules/ai-foundry` module, wired into `infra/main.bicep` | No |
| 4 | Single-tenant Entra app registration + its service principal | Application Administrator (or Cloud Application Administrator) | Microsoft Graph Bicep extension: `Microsoft.Graph/applications` + `Microsoft.Graph/servicePrincipals` | No |
| 5 | Delegated permission `WorkIQAgent.Ask` (scope ID `0b1715fd-f4bf-4c63-b16d-5be31f9847c2`) on the app | Same as 4 | `requiredResourceAccess` on the Graph `applications` resource | No |
| 6 | Tenant-wide admin consent for `WorkIQAgent.Ask` | Global Admin per the article (PIM, just in time) | `Microsoft.Graph/oauth2PermissionGrants` with `consentType: 'AllPrincipals'`, deployed in the tenant bootstrap | No |
| 7 | Client secret for the app, stored in Key Vault | Application owner | Graph Bicep **cannot** create `passwordCredentials`. The `postprovision` hook calls `az ad app credential reset --append` (Graph `addPassword`) and writes the value straight into Key Vault | No |
| 8 | Foundry project connection `RemoteA2A` / `OAuth2` to `https://workiq.svc.cloud.microsoft/a2a/` | Foundry Project Manager on the project | `postprovision` hook: `az rest --method put` against the ARM connections API, with the secret read from Key Vault in memory | No |
| 9 | The connection's `properties.oauthRedirectUrl` added as a **Web** redirect URI on the app | Application owner | Same hook reads the PUT response, then `az ad app update --web-redirect-uris`; also saved to the azd env so the next Bicep run keeps it | No |
| 10 | Foundry User on the project **and** account for developers, the agent runtime identity, and every OAuth end user | Role Based Access Control Administrator | Bicep `roleAssignments`, assigned to an Entra security group created by Graph Bicep | No |
| 11 | Foundry Project Manager on the project for whoever creates the connection | Same as 10 | Bicep `roleAssignments` for the deployer principal | No |
| 12 | Prompt agent with `WorkIQPreviewTool` attached directly (no toolbox) | Foundry User | .NET console app `src/WorkIQAgent` (the article's C# prompt-agent sample, parameterised from azd env outputs) | No |
| 13 | Each end user's first OAuth consent for the connection | Each end user | Not automatable by design; the agent run returns a consent link the first time | Sign-in prompt only, not the Azure portal |

Result: **one portal visit** (Copilot Credits billing, #1), and it is a
Microsoft 365 admin center step, not an Azure one. Everything else runs from
scripts, Bicep and `azd` hooks.

## Architecture of the automation

```text
 one time per tenant (Global Admin via PIM)          per environment (azd up)
 ───────────────────────────────────────────         ──────────────────────────────────────────────
 scripts/bootstrap-tenant.ps1                        preprovision  (existing: tags + preflight
   ├─ az ad sp create --id fdcc1f02-…   (#2)                       + new Work IQ checks)
   └─ deploys infra/entra/main.bicep    (#4,5,6,10)  provision     infra/main.bicep
        ├─ Graph application + SP                      ├─ monitoring (existing)
        ├─ requiredResourceAccess WorkIQAgent.Ask      ├─ ai-foundry: account, project, model (#3)
        ├─ oauth2PermissionGrant AllPrincipals         ├─ key-vault (for the client secret)
        └─ "Work IQ users" security group              └─ role assignments (#10, #11)
   outputs → azd env: WORKIQ_APP_ID,                 postprovision scripts/configure-workiq.ps1
             WORKIQ_USERS_GROUP_ID                     ├─ addPassword → Key Vault        (#7)
                                                       ├─ PUT RemoteA2A connection       (#8)
 (M365 admin center, once) Copilot Credits     (#1)    └─ patch app redirect URI         (#9)
                                                     dotnet run --project src/WorkIQAgent (#12)
```

### Why the Entra resources sit in a separate Bicep file

- This repository's lifecycle gates every deployment on `azd provision --preview`
  (what-if). The Graph Bicep extension
  [does not support what-if](https://learn.microsoft.com/graph/templates/bicep/limitations),
  so Graph resources in `infra/main.bicep` would break that gate.
- The tenant-wide consent grant needs Global Admin. Keeping it out of the
  per-environment deployment means the day-to-day deployer needs no directory
  role beyond app ownership.
- Run the bootstrap once per tenant; it is idempotent (Graph Bicep upserts by
  `uniqueName`). Additional environments can reuse the same app (one redirect
  URI per connection) or get their own app by passing a different `uniqueName`.

## Running Phases 0 and 1

```powershell
# Once per tenant, as Global Administrator (activate it through PIM first).
az login --tenant $tenantId
./scripts/bootstrap-tenant.ps1   # writes WORKIQ_APP_ID, WORKIQ_APP_OBJECT_ID, WORKIQ_USERS_GROUP_ID

# Per environment, as the deployer.
azd env set AZURE_FEATURE_OVERRIDES_JSON '{"aiFoundry":true}'
azd provision --preview
```

The bootstrap runs `az deployment sub create`, so the administrator also needs
`Microsoft.Resources/deployments/write` on the subscription. Re-running it is
safe and keeps the redirect URIs already on the app registration. After the
bootstrap, enable Copilot Credits billing in the Microsoft 365 admin center
and add the "Foundry Work IQ users" group to a spending policy that includes
the Work IQ API.

`aiFoundry` is off in every profile, as catalog modules are. Turning it on
also deploys the Key Vault. `infra/main.parameters.json` reads
`WORKIQ_USERS_GROUP_ID`, `AZURE_PRINCIPAL_ID` and `AZURE_PRINCIPAL_TYPE`
(default `User`; set it to `ServicePrincipal` in CI).

## Work breakdown

### Phase 0: Tenant prerequisites (one time, human with Global Admin via PIM)

1. **Copilot Credits billing (portal, M365 admin center).** Activate the default
   spending policy and include the Work IQ API. Add the "Work IQ users" group
   (created in step 3) to the policy. Without this, calls return `403`.
2. **`scripts/bootstrap-tenant.ps1`** (new). It:
   - Asserts that the signed-in user holds an active Global Administrator
     assignment (Graph `me/transitiveMemberOf`), and fails with a PIM hint otherwise.
   - Runs `az ad sp create --id fdcc1f02-fc51-4226-8753-f668596af7f7` and
     treats the "already exists" conflict as success.
   - Deploys `infra/entra/main.bicep` with `az deployment group create` (or
     `az deployment sub create`), then writes the outputs to the azd env with
     `azd env set`.
3. **`infra/entra/main.bicep`** (new, `extension microsoftGraphV1`):
   - `Microsoft.Graph/applications@v1.0`: `uniqueName`, `signInAudience: 'AzureADMyOrg'`,
     `requiredResourceAccess` → resourceAppId `fdcc1f02-…`, scope
     `0b1715fd-…`, type `Scope`; `web.redirectUris` from the
     `workIqRedirectUris` parameter (empty on the first run).
   - `Microsoft.Graph/servicePrincipals@v1.0` for the app.
   - `existing` reference to the Work IQ service principal by `appId`.
   - `Microsoft.Graph/oauth2PermissionGrants@v1.0`: `clientId` = app SP id,
     `resourceId` = Work IQ SP id, `consentType: 'AllPrincipals'`,
     `scope: 'WorkIQAgent.Ask'`. This is the admin consent.
   - `Microsoft.Graph/groups@v1.0` "Work IQ users" (security group, not role-assignable).
   - Owners: the deploying user, so the per-environment hook can add secrets
     and redirect URIs without a directory role.
   - Outputs: `appId`, `appObjectId`, `usersGroupId`.
4. **`bicepconfig.json`** (new, repository root or `infra/`): pin
   `extensions.microsoftGraphV1` to a specific
   `br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:<version>`.

### Phase 1: Azure resources (`infra/main.bicep`, per environment)

5. Wire the existing `ai-foundry` module into `infra/main.bicep` behind a new
   `aiFoundry` feature flag (the README already carries the wire-up snippet).
   Deploy one model the article's sample uses (`gpt-5-mini`, GlobalStandard)
   and check its quota in preflight.
6. Enable `key-vault` (already in the catalog) for `core` as well, through the
   feature override, with RBAC authorization.
7. Role assignments (role definition IDs, not names, because of the rename rollout):

   | Principal | Role | ID | Scope |
   |---|---|---|---|
   | "Work IQ users" group | Foundry User | `53ca6127-db72-4b80-b1b0-d745d6d5456d` | project **and** account (the troubleshooting table requires both) |
   | Deployer (`AZURE_PRINCIPAL_ID`) | Foundry Project Manager | `eadc314b-1a2d-4efa-be10-5d325db5065e` | project |
   | Deployer | Foundry User | `53ca6127-…` | project and account |
   | Deployer | Key Vault Secrets Officer | `b86a8fe4-44ce-4948-aee5-eccb2c155cd7` | vault |
   | Project managed identity | Key Vault Secrets User | `4633458b-17de-408a-b874-0445c86b69e6` | vault (only if a later connection references the vault) |

   New parameters: `workIqUsersGroupId` and `workIqAppId` (from the bootstrap
   azd env values), `principalId` (azd's `AZURE_PRINCIPAL_ID`).
8. New outputs for the hook and the app: `FOUNDRY_PROJECT_ENDPOINT`,
   `FOUNDRY_PROJECT_ID`, `FOUNDRY_ACCOUNT_NAME`, `KEY_VAULT_NAME`,
   `WORKIQ_CONNECTION_NAME`.

### Phase 2: Connection wiring (`postprovision` hook, `scripts/configure-workiq.ps1`)

9. **Secret.** If Key Vault has no current `workiq-client-secret`, run
   `az ad app credential reset --id $WORKIQ_APP_ID --append --display-name foundry-workiq --years 1`
   and pipe the value straight to `az keyvault secret set` with an
   `expires` attribute. Never echo it, never `azd env set` it (azd writes
   `.env` files in plain text).
10. **Connection.** `az rest --method put` to
    `.../accounts/{account}/projects/{project}/connections/{name}?api-version=2025-04-01-preview`
    with the body from the article (`category: RemoteA2A`, `authType: OAuth2`,
    tenant-specific authorize/token/refresh URLs, scopes
    `api://workiq.svc.cloud.microsoft/WorkIQAgent.Ask` and `offline_access`).
    Send the body from a temporary file in the scratch directory that is
    deleted in a `finally` block, so the secret never shows on a command line.
    The connection is immutable: when the client ID or secret changes, the
    hook deletes and recreates it (the article: "You can't edit connection
    fields after creation").
11. **Redirect URI.** Read `properties.oauthRedirectUrl` from the PUT response,
    merge it into the app's existing `web.redirectUris` with
    `az ad app update --web-redirect-uris`, and `azd env set WORKIQ_REDIRECT_URI`
    so the next bootstrap run passes it to Graph Bicep instead of removing it.
12. **Why not Bicep for the connection?** The ARM type
    `Microsoft.CognitiveServices/accounts/projects/connections` exists, but
    putting the secret in a deployment parameter stores it in deployment
    history, and the redirect URL then has to round-trip through outputs. Keep
    it in the hook unless a later API version supports Key Vault references
    for OAuth2 connections.

### Phase 3: The .NET agent (`src/WorkIQAgent`)

13. A console project that mirrors the article's .NET prompt-agent sample:
    `Azure.AI.Projects` (pin the version that ships `WorkIQPreviewTool`) and
    `Azure.Identity`. It reads `FOUNDRY_PROJECT_ENDPOINT` and
    `WORKIQ_CONNECTION_NAME` from `azd env get-values`, resolves the connection
    with `Connections.GetConnection`, and creates a `DeclarativeAgentDefinition`
    whose `Tools` holds `new WorkIQPreviewTool(connection.Id)`. No toolbox is
    created or referenced. It sends one query with `ToolChoice = required`,
    and prints the consent link when the first run needs one.

### Phase 4: Preflight, tests and docs (fit the repository's gates)

14. `scripts/preflight.ps1`: when `aiFoundry` is on, check that the
    `WORKIQ_APP_ID` and `WORKIQ_USERS_GROUP_ID` azd env values exist, that the
    Work IQ service principal exists (`az ad sp show --id fdcc1f02-…`), that the
    admin consent grant exists, and that model quota is available in the region.
15. `tests/`: a module test for the new connection/role wiring, catalog
    conformance for any new module (`scripts/new-module.ps1`), and
    `build-catalog.ps1 -Check` / `build-docs.ps1 -Check`.
16. Docs: a Work IQ section in `docs/deployment.md` (bootstrap, roles, the one
    portal step), and a secret-rotation runbook: append a new password, update
    Key Vault, recreate the connection, then remove the old password.
17. Record decisions in `.azure/deployment-plan.md`: no toolbox (direct
    `WorkIQPreviewTool` on a prompt agent), the data-boundary warning
    from the article (Work IQ traffic can leave the Azure compliance boundary),
    preview status, and that `publicNetworkAccess` stays `Enabled` for now.

## Privileges summary

| Who | When | Needs |
|---|---|---|
| Tenant admin | Once (Phase 0) | Global Administrator through PIM for the Work IQ SP and admin consent; Global or Billing Admin for Copilot Credits |
| Deployer | Each `azd up` | Contributor + Role Based Access Control Administrator on the subscription or resource group; owner of the Entra app (granted by the bootstrap) |
| Developers / end users | Daily | Member of "Work IQ users" (grants Foundry User), in the Copilot Credits spending policy, plus their own OAuth consent on first use |

## Risks and open questions

- **Preview APIs.** The connection API version (`2025-04-01-preview`), the
  `WorkIQPreviewTool` type and the `Azure.AI.Projects` SDK can change. Pin
  versions, and keep the hook's HTTP calls in one function so they are easy to
  update.
- **Endpoint drift.** The article notes that an older Work IQ target,
  `https://agent365.svc.cloud.microsoft/agents/agents/workiq`, was in use before. Make the target
  a parameter, defaulting to `https://workiq.svc.cloud.microsoft/a2a/`.
- **Admin consent role.** The article says Global Administrator. Cloud
  Application Administrator can usually consent to non-Graph delegated
  permissions; test that in the tenant before you rely on the lower role.
- **Entra replication delay.** Role assignments to a newly created group or app
  can fail on the first attempt. Set `principalType` explicitly and retry in
  the hook.
- **Secret lifetime.** A client secret is the only credential the connection
  accepts today (no certificate or federated credential option is documented).
  Set an expiry, and add an alert or a scheduled rotation.
- **Redirect URL shape.** It is returned only after the connection exists, so
  the plan treats it as dynamic. If it turns out to be deterministic, it can
  move into `infra/entra/main.bicep` and step 11 goes away.
- **Copilot Credits billing** has no documented API. Revisit if Microsoft adds
  Graph or PowerShell support for spending policies.
