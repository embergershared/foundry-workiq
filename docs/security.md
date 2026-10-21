# Security and private access

The starter is private by default in the `private` and `full` profiles: VM NICs
have no public IP, Storage and Key Vault public network access is disabled,
shared-key Storage access and local Application Insights authentication are
disabled, and workload access uses managed identity/Entra RBAC.

Profile affects the surface. Read this page alongside the profile you are
deploying:

| Profile | Security posture |
|---|---|
| `core` | No network is created, so there is no private DNS and no private endpoint. Any catalog module you add deploys public-with-firewall. Managed identity, Entra RBAC, disabled shared keys and disabled local authentication still apply. |
| `private` | Private endpoints and VNet-linked private DNS for every module that supports Private Link; public network access disabled on those services. |
| `full` | Everything in `private`, plus the brokered administration path and the approved public exceptions below. |

Adding a data service to a `core` project is a deliberate trade-off: without a
VNet, the service is reachable from the internet subject to its own firewall and
Entra authorization. If the data is sensitive, use `private` instead of relying
on a service firewall alone.

## Approved public exceptions

| Exception | Why | Guardrail |
|---|---|---|
| Standard Bastion public IP in `full` | Brokered administration | HTTPS to Bastion only; RDP/SSH reaches VMs only from the Bastion subnet |
| NAT public IP in `full` | Entra VM extension/bootstrap egress | Jumpbox subnet association only; outbound-only |
| Azure Monitor public ingestion/query | Keep Log Analytics and Application Insights usable without private link | Local authentication disabled; Entra authorization and resource-scoped access remain required |
| Public-with-firewall services in `core` | The profile deploys no VNet to put an endpoint in | Service firewall plus Entra RBAC; no shared keys; step up to `private` when that is not enough |

Any additional public endpoint, firewall bypass, or broad NSG rule requires a
documented security decision and validation. Azure Monitor public access is an
intentional exception and organizational policy may reject it.

## Private DNS

In the `private` and `full` profiles the VNet links one non-registering zone per
Private Link endpoint declared in the [module catalog](modules.md), currently:

- `privatelink.vaultcore.azure.net`
- `privatelink.blob.core.windows.net`
- `privatelink.file.core.windows.net`

The zone list is generated from module metadata into
`infra/core/private-dns-zones.json`, so adding a module with a private endpoint
adds and links its zone automatically. Review the resulting zone before
deploying it into a network with existing DNS.

Clients must resolve service FQDNs through the VNet-linked zones to private
endpoint addresses. For custom/on-premises DNS, use conditional forwarding
through Azure DNS Private Resolver or an Azure DNS forwarder. Do not forward
directly to a private endpoint IP or create duplicate/conflicting zones. Test
with `Resolve-DnsName`/`nslookup` from the jumpbox or another VNet-connected
client. See [Azure private endpoint DNS](https://learn.microsoft.com/azure/private-link/private-endpoint-dns).

## Azure Monitor access

Log Analytics and workspace-based Application Insights explicitly enable public
ingestion and query. Application Insights local authentication remains
disabled, so clients must use Microsoft Entra authentication rather than
instrumentation-key authentication. Keep Azure RBAC least-privileged and review
the public monitoring exception against subscription policy before deployment.

## Entra primary and break glass (`full` profile only)

Entra VM login is the primary administrative path. The template creates local
usernames and generated passwords only for emergency recovery, stores them as
secrets in the template-created private Key Vault, and grants configured
operators **Key Vault Secrets User**.

Key Vault is RBAC-enabled, purge-protected, public-disabled, and
`enabledForTemplateDeployment`. That last setting lets the ARM/Bicep deployment
retrieve secure secret values for VM provisioning; it does not make the vault
public or expose secrets as outputs.

The passwords use Bicep-generated secure defaults. **Reprovisioning generates
and stores new values**, and VMAccess extensions reset the guest accounts to
the same values before the deployment succeeds. Previously retrieved values
must therefore be treated as expired. Always retrieve the current secret from
a VNet-connected client and never print, log, copy into tickets, or commit it.
Portal secret reads from an internet-only workstation fail by design because
the vault data plane is private.

In full profile, NAT is required for Entra extensions and login bootstrap. An
air-gapped override must set both `natGateway=false` and `entraLogin=false`;
this deliberately removes Entra as the primary login path and requires an
approved break-glass and patching plan before deployment.
