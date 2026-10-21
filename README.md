# Azure `azd` starter

A universal starting point for Azure projects. Every project gets the same
conventions layer — deterministic naming, an approved region catalog, a stable
subscription code, common lifecycle tags, `azd` wiring, preflight validation and
a test suite that enforces all of it. Infrastructure beyond that is opt-in.

Start with `core` — a resource group, tags and monitoring — and add exactly the
resources the project needs from the [module catalog](docs/modules.md). Step up
to `private` when the project needs a VNet and private endpoints, or `full` when
it needs a desktop inside that VNet.

## Start here

1. In a repository created from this template, record your tenants and
   subscriptions; see
   [Starting a repository from the template](docs/deployment.md#starting-a-repository-from-the-template).
   Your targets are listed in [docs/targets.md](docs/targets.md).
2. Review [prerequisites and required roles](docs/deployment.md#prerequisites-and-roles).
3. Choose a [deployment profile](#deployment-profiles) and, if needed,
   [expert overrides](docs/configuration.md#expert-feature-overrides).
4. Follow the gated [prepare → validate → deploy lifecycle](docs/deployment.md).
5. Add the resources you need from the [module catalog](docs/modules.md).

```powershell
# Variables values
$tenantId = '<tenant-guid>' # must be listed in infra/core/tenant-codes.json
$subscriptionId = '<subscription-guid>'
# Use a lowercase, unique 2-32 character environment name.
$environment = 'my-azd-env-dev'
$location = 'eastus2'
$deploymentProfile = 'core' # core, private, or full

# Commands execution
az login --tenant $tenantId
az account set --subscription $subscriptionId
azd auth login --tenant-id $tenantId
azd env new $environment --subscription $subscriptionId --location $location
azd env set DEPLOYMENT_PROFILE $deploymentProfile
.\scripts\set-deployment-tags.ps1
azd provision --preview -e $environment
```

The `full` profile additionally requires an operator principal, because it
grants VM sign-in rights:

```powershell
azd env set AZURE_OPERATOR_PRINCIPAL_IDS (az ad signed-in-user show --query id --output tsv)
```

Preview is not deployment. Do not run `azd provision` or `azd up` until the
validation gate and deployment approval are complete.

Run `set-deployment-tags.ps1` once after creating an environment. AZD resolves
required Bicep inputs before `preprovision` hooks run; the script seeds those
first-use values, including the stable subscription code, and the hook refreshes
update metadata on later provisions. When `AZURE_SUBSCRIPTION_ID` is not set,
the script uses the subscription the Azure CLI is signed in to, and both scripts
fail if the Azure CLI and `azd` target different subscriptions. The subscription
code comes from a final `-<N>` display-name token (`-1` gives `s1`), a delimited
`s<N>` token (`Contoso-s2-Sandbox` gives `s2`), or the subscription ID. To
target another tenant or subscription, see
[Deploy to another tenant or subscription](docs/deployment.md#deploy-to-another-tenant-or-subscription).

## Deployment profiles

Set the profile in the selected AZD environment before previewing or
provisioning:

```powershell
azd env set DEPLOYMENT_PROFILE core # core, private, or full
```

Profiles are a cumulative ladder. Each rung adds to the one below it:

| `DEPLOYMENT_PROFILE` | Deploys | Use it when |
|---|---|---|
| `core` *(default)* | Resource group, common tags, Log Analytics, and Application Insights | The project has no networking requirement — the majority of projects |
| `private` | Everything in `core`, plus VNet, subnets and NSGs, private DNS zones, and a private Key Vault and Storage account | The project must be private by default |
| `full` | Everything in `private`, plus Standard Bastion, Windows 11 and Ubuntu jumpboxes, NAT Gateway, Entra VM login, operator RBAC, and VM auto-shutdown | Someone needs a desktop inside the VNet |

`core` deploys no virtual network, no private endpoints, and no private DNS. It
does not force Key Vault or Storage on a project either — those are catalog
modules you opt into.

`minimal` is accepted as a deprecated alias for `private` and emits a warning.
Update existing environments with
`azd env set DEPLOYMENT_PROFILE private`.

Moving down the ladder stops deploying disabled resources; ARM incremental
deployments can retain the existing VNet, Bastion, VMs and other resources, which
may continue billing. Inspect `azd provision --preview` before a profile change.
Cleanup is a separate, explicitly approved operation after reviewing data
retention, identities, dependencies and rollback/recovery; a downgrade is not cleanup.

For combinations between the rungs, use the documented
[expert feature overrides](docs/configuration.md#expert-feature-overrides).
Dependency validation still applies; for example, jumpbox VMs require Bastion,
and Entra VM login requires NAT egress.

## What is always present

The conventions layer ships with every profile, including `core`:

| Location | What it provides |
|---|---|
| `infra/core/naming.bicep` | Exported naming functions — the single definition of the naming contract |
| `infra/core/tags.bicep` | The exported common-tag function |
| `infra/core/private-endpoint.bicep` | The one private endpoint and DNS pattern every module uses |
| `infra/core/abbreviations.json` | Approved Cloud Adoption Framework resource abbreviations |
| `infra/core/tenant-codes.json` | The approved tenant-code catalog, keyed by Entra tenant ID; a new repository starts from `tenant-codes.example.json` |
| `docs/targets.md` | This repository's tenants, subscriptions and default target; a new repository starts from `targets.example.md` |
| `scripts/init-from-template.ps1` | Replaces the template owner's specifics with the examples in a new repository |
| `infra/core/location-codes.json` | The approved region-code catalog |
| `infra/core/name-rules.json` | Per-resource length, charset and scope rules |
| `scripts/preflight.ps1` | Fail-closed validation before any deployment |
| `scripts/set-deployment-tags.ps1` | Subscription code, lifecycle tags, and override transport |
| `tests/` | The suite that proves names, rules, catalog and profiles are intact |

## Adding resources

Resources live in a self-describing catalog under `infra/modules/`. Each module
carries its own `metadata.json`, and preflight's provider list, the private DNS
zone list and the documentation tables are all derived from it.

```powershell
./scripts/new-module.ps1 -Name service-bus -Abbreviation sbns -Provider Microsoft.ServiceBus -ResourceType Microsoft.ServiceBus/namespaces -ApiVersion 2022-10-01-preview
./scripts/add-module.ps1 -Module service-bus    # generate supported wiring; complete printed declarations
./scripts/promote-module.ps1 -From <path>       # bring a proven module back into the catalog
./scripts/adopt-conventions.ps1 -Path <repo>    # push the conventions into an existing repo
```

See [the module catalog](docs/modules.md) for the contract, the current
catalog, and how to author and promote a module.

## Testing

```powershell
./tests/run-tests.ps1
```

The suite proves that resource names have not drifted, that every name obeys its
resource rules, that the catalog is in sync, that all Bicep builds and lints
clean, and that `core` produces no `Microsoft.Network` or `Microsoft.Compute`
resources.

## Documentation

- [Architecture and extension points](docs/architecture.md)
- [Module catalog and lifecycle scripts](docs/modules.md)
- [Profiles and expert overrides](docs/configuration.md)
- [Deployment, access, cost, and teardown](docs/deployment.md)
- [Security, private DNS, monitoring access, and break glass](docs/security.md)

Environments deployed by an earlier revision with Azure Monitor private link
require the ordered cleanup described in
[deployment migration guidance](docs/deployment.md#migrating-an-environment-that-previously-used-azure-monitor-private-link)
before reprovisioning.

This repository also contains an installed Squad workspace. Do not repurpose or
rewrite Squad-owned files under `.squad/templates/`, the coordinator agent, or
the installed Squad workflows.
