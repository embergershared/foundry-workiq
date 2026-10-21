# Deployment lifecycle

Use three gated phases. The template is infrastructure-only, so `azd provision`
is the deployment operation; `azd deploy` has no application service to publish.

Requirements scale with the [deployment profile](configuration.md#profiles). A
`core` deployment needs far less than a `full` one, and the sections below mark
which requirements are conditional.

## Prerequisites and roles

Install current [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
and [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd),
with PowerShell 7 available for hooks. Authenticate to the intended tenant and
verify subscription, region, policy, resource providers, quota, and SKU/image
availability immediately before preview.

The deployment identity needs:

- **Contributor** at subscription scope (or equivalent custom permissions) to
  create the resource group and resources. Required in every profile.
- **Role Based Access Control Administrator**, **User Access Administrator**, or
  equivalent `Microsoft.Authorization/roleAssignments/*` permission at the
  deployment scopes when `roleAssignments` is enabled.
- Read access to subscription, provider, quota, SKU, and Marketplace image
  metadata used by preflight. Preflight only queries the providers the enabled
  modules declare, so a `core` deployment makes no compute or network calls.

  The subscription code comes from the display name's final hyphen-delimited
  1-4 digit token (`-3` gives `s3`) or a delimited `s<N>` token
  (`Contoso-s2-Sandbox` gives `s2`), falling back to the subscription ID.
  The initialization helper caches it for resource naming, and preflight blocks
  if a later subscription rename would change it.

Configured operator principals receive:

- **Virtual Machine User Login** on each Entra-enabled VM.
- **Key Vault Secrets User** on the Key Vault.
- **Storage Blob Data Contributor** and **Storage File Data SMB Share
  Contributor** on the Storage account.

`AZURE_OPERATOR_PRINCIPAL_IDS` is therefore only required when the deployment
enables a VM or role assignments. A `core` deployment passes preflight without
it.

Role changes can take time to propagate. Use Entra object IDs, not display names.
If automatic assignments are disabled, have an authorized administrator apply
the same least-privilege roles before access testing. Review the authoritative
[Azure built-in role definitions](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles)
when permissions or role IDs change.

### Jumpbox requirements (`full` profile only)

Windows 11 Pro is license-gated. Preflight queries the exact
`MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest` offer in the target
subscription and region and blocks when it is unavailable. This check does not
grant a license or replace your organization's entitlement review. Never
silently substitute another Windows edition. Review Microsoft's
[Windows client image licensing guidance](https://learn.microsoft.com/azure/virtual-machines/windows/client-images)
before approving the profile.

Both jumpboxes use the standard Azure VM Agent for provisioning and extensions.
The template does not require the subscription-gated
`Microsoft.Compute/Agentless` feature.

Windows 11 uses OS-managed automatic updates because this client image does not
support Azure-orchestrated VM Guest Patching. Ubuntu retains
Azure-orchestrated patch assessment and installation. Entra login and VMAccess
extensions accept minor-version upgrades but do not opt into automatic
extension upgrades because these extension publishers do not support that
property.

The Windows Entra extension always receives the case-sensitive `mdmId` setting.
Its default empty value enables Entra login without requesting automatic MDM
enrollment. Configure an approved MDM application ID only when enrollment is
intentional and licensed for the target tenant.

## 1. Prepare

1. Review `.azure/deployment-plan.md`, architecture, public exceptions, budget,
   policy, identity, address space, recovery, and unresolved risks.
2. Create/select an environment and set the values in
   [configuration](configuration.md).
3. Review generated names and the preview target. Preparation must not change
   Azure.

```powershell
az login --tenant <tenant-guid>
az account set --subscription <subscription-guid>
azd auth login --tenant-id <tenant-guid>
azd env new <environment> --subscription <subscription-guid> --location eastus2
azd env set DEPLOYMENT_PROFILE core
# Only when the profile or an override enables a VM or role assignments:
azd env set AZURE_OPERATOR_PRINCIPAL_IDS <entra-object-guid>
.\scripts\set-deployment-tags.ps1
```

The final command is a required one-time bootstrap for each new environment.
It initializes the stable subscription code and lifecycle values. AZD resolves
required Bicep parameters before running pre-provision hooks; later provisions
verify the code and refresh update metadata automatically.

If `AZURE_SUBSCRIPTION_ID` is not set, the bootstrap uses the subscription the
Azure CLI is signed in to. The bootstrap and preflight both fail when the Azure
CLI and `azd` target different subscriptions.

### Starting a repository from the template

The template repository commits its owner's tenants and subscriptions in
[`docs/targets.md`](targets.md) and `infra/core/tenant-codes.json`. Each has an
`.example` sibling with placeholder values. On a new repository's first push to
`main`, the `template-init` workflow runs `scripts/init-from-template.ps1`,
which copies each example over its specifics file and commits the result. If
the workflow did not run (Actions disabled, or read-only workflow permissions),
run the script yourself before the first deployment:

```powershell
./scripts/init-from-template.ps1
```

Then record your own tenants in both files, as described below. Preflight and
Bicep fail closed until the deployment's tenant is listed, so the example
catalog cannot be deployed by mistake. Commit both files; they are this
repository's specifics from then on, and the workflow never runs again.

### Deploy to another tenant or subscription

The approved tenants are the ones listed in `infra/core/tenant-codes.json`, and
[`docs/targets.md`](targets.md) records them with their subscriptions and the
default target. Nothing else in the template is tied to a tenant or
subscription. To target another one:

1. **Approve the tenant.** Add it to `infra/core/tenant-codes.json` before its
   first deployment, as described in
   [resource naming](configuration.md#resource-naming). Preflight and Bicep
   both fail closed for an unlisted tenant. Use an empty code only when the
   tenant's resources must keep names without a tenant segment.
2. **Sign both CLIs in to that tenant.** The Azure CLI and `azd` keep separate
   logins, and the scripts check that they agree:

   ```powershell
   az login --tenant <tenant-guid>
   az account set --subscription <subscription-guid>
   azd auth login --tenant-id <tenant-guid>
   ```

3. **Use a new environment per subscription.** Names, the cached subscription
   code and the lifecycle tags belong to one subscription, so do not repoint an
   existing environment:

   ```powershell
   azd env new <environment> --subscription <subscription-guid> --location <region>
   .\scripts\set-deployment-tags.ps1
   ```

4. **Check the subscription code.** Display names such as
   `Contoso-s3-Projects` give `s3`. A name without a `-<N>` suffix or an
   `s<N>` token, such as `Pay as you go`, falls back to `s` plus the first four
   hex characters of the subscription ID; choose a readable one before the
   first provision with `azd env set AZURE_SUBSCRIPTION_CODE s1`.
5. **Register providers and check quota** in the new subscription. Preflight
   reports unregistered providers but never registers them.

## 2. Validate

Run the test suite, then preview. The suite covers naming equivalence and
name-rule compliance, module catalog conformance, `az bicep build` and
`az bicep lint` over `infra/main.bicep` and every catalog module, and the
`core`/`private`/`full` profile matrix. The pre-provision hook then checks
configuration dependencies, provider registration for the modules actually
enabled, target location, and — only when the relevant feature is on — operator
IDs, VM SKU quota/restrictions, and Windows image visibility.

```powershell
Get-ChildItem -Recurse -Filter *.json |
  ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json | Out-Null }
.\scripts\build-catalog.ps1 -Check
.\tests\run-tests.ps1
azd provision --preview -e <environment>
```

Inspect every create/change/delete and recurring-cost resource. Resolve policy,
quota, role, licensing, DNS, and dependency failures; do not bypass preflight.
Record evidence in the deployment plan and complete `azure-validate`.

### Migrating an environment that previously used Azure Monitor private link

ARM deployments are incremental, so removing private-link resources from Bicep
does not delete every previously deployed resource. Before provisioning this
revision over an environment that used Azure Monitor private link, remove only
the obsolete monitor private endpoint and its NIC, private-link scope, four
monitor-only private DNS zones/links, monitor subnet, and monitor NSG. Delete
the private endpoint before its subnet.

Do **not** delete the Log Analytics workspace or Application Insights. After
cleanup, run preview again and verify that both resources change
`publicNetworkAccessForIngestion` and `publicNetworkAccessForQuery` to
`Enabled`, with no monitor private-link resources being created.

## 3. Deploy and verify

After explicit approval, run:

```powershell
azd provision -e <environment>
```

Verify actual resource state, private DNS resolution, public-access settings,
operator RBAC, Entra login, current break-glass retrieval, monitoring ingestion,
and every enabled profile feature. A successful command alone is insufficient.

## Standard Bastion access (`full` profile only)

VMs have no public IP. From the Azure portal, open the VM, select
**Connect → Bastion**, and use Entra credentials where supported. Standard
Bastion also supports native clients:

```powershell
az network bastion rdp --name <bastion> --resource-group <resource-group> --target-resource-id <windows-vm-resource-id> --auth-type AAD
az network bastion ssh --name <bastion> --resource-group <resource-group> --target-resource-id <linux-vm-resource-id> --auth-type AAD
```

See [Bastion native-client access](https://learn.microsoft.com/azure/bastion/connect-vm-native-client-windows).
Do not add VM public IPs or internet RDP/SSH rules for convenience.

## Cost, shutdown, and teardown

Check current regional prices before approval. A `core` deployment's only
recurring charge is Log Analytics ingestion and retention. The largest idle
charges in the higher profiles usually come from Standard Bastion, VMs/disks,
NAT Gateway and public IPs, and private endpoints. The daily cap limits
ingestion, not all monitoring charges.

Choosing the lowest profile that satisfies the project is the primary cost
control. `core` is the default for that reason.

Full-profile shutdown schedules stop VM compute daily at `1900` Eastern by
default. They do not remove disk, Bastion, NAT, public IP, private endpoint, or
monitoring charges, and they do not restart VMs automatically.

For an ephemeral PoC, verify the environment contains no shared resources, then:

```powershell
azd down -e <environment>
```

Review and confirm the destructive plan. Verify the resource group is gone and
check for soft-deleted/purge-protected Key Vault state and any retained charges.
