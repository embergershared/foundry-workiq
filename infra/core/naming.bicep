// Shared naming conventions for every project built from this template.
//
// Contract (do not change without accepting resource replacement):
//   <resource-prefix>-<tenant-code>-<location-code>-<subscription-code>-<environment>
//
// The tenant code comes from infra/core/tenant-codes.json, keyed by tenant ID,
// so it survives subscription renames. A tenant whose catalog code is empty
// keeps the pre-tenant <resource-prefix>-<location-code>-... names.
//
// Globally unique names (Key Vault, storage accounts) spend a fixed budget and
// truncate ONLY the environment segment, so the prefix, location, subscription
// and uniqueness hash always survive. They carry no tenant code: it does not fit
// the 24-character budget, and the hash already differs per subscription.
//
// Two Bicep constraints shape these signatures:
//   1. A user-defined function cannot call subscription(), tenant(),
//      reference() or any list*() function. `tenantCode`, `locationCode` and
//      `shortHash` are therefore resolved by the caller and passed in.
//   2. User-defined function parameters cannot declare defaults. Every argument
//      is passed explicitly (pass '' for an unused suffix).

@export()
@description('Resource-type abbreviations used as the leading name segment.')
var abbreviations = loadJsonContent('./abbreviations.json')

@export()
@description('Approved short codes for Azure public-cloud regions.')
var locationCodes = loadJsonContent('./location-codes.json')

@export()
@description('Approved tenant codes, keyed by lowercase Entra tenant ID.')
var tenantCodes = loadJsonContent('./tenant-codes.json')

@export()
@description('Per-resource-type length, charset and scope rules.')
var nameRules = loadJsonContent('./name-rules.json')

@export()
@description('Resolves an Azure region to its approved short code.')
func locationCodeFor(location string) string => string(locationCodes[toLower(location)])

@export()
@description('Resolves an Entra tenant ID to its approved lowercase tenant code.')
func tenantCodeFor(tenantId string) string => toLower(string(tenantCodes[toLower(tenantId)].code))

@export()
@description('Normalizes an environment name for names that forbid hyphens or uppercase.')
func normalizeEnvironment(environmentName string) string => toLower(replace(environmentName, '-', ''))

@export()
@description('The shared [<tenant>-]<location>-<subscription>-<environment> body of every regional name.')
func baseName(tenantCode string, locationCode string, subscriptionCode string, environmentName string) string =>
  empty(tenantCode)
    ? '${locationCode}-${subscriptionCode}-${environmentName}'
    : '${tenantCode}-${locationCode}-${subscriptionCode}-${environmentName}'

@export()
@description('Standard regional resource name. Pass an empty suffix when the resource needs no role qualifier.')
func azName(
  abbreviation string,
  tenantCode string,
  locationCode string,
  subscriptionCode string,
  environmentName string,
  suffix string
) string =>
  empty(suffix)
    ? '${abbreviation}-${baseName(tenantCode, locationCode, subscriptionCode, environmentName)}'
    : '${abbreviation}-${baseName(tenantCode, locationCode, subscriptionCode, environmentName)}-${suffix}'

@export()
@description('Globally unique name constrained to a character budget. Only the environment segment is truncated. Use separator \'-\' for Key Vault and \'\' for storage accounts.')
func globalName(
  abbreviation string,
  locationCode string,
  subscriptionCode string,
  environmentName string,
  shortHash string,
  separator string,
  budget int
) string =>
  '${abbreviation}${separator}${locationCode}${separator}${subscriptionCode}${separator}${take(normalizeEnvironment(environmentName), max(1, budget - length('${abbreviation}${separator}${locationCode}${separator}${subscriptionCode}${separator}${separator}${shortHash}')))}${separator}${shortHash}'

@export()
@description('Name of the platform-managed resource group a service creates for its own infrastructure (Container Apps environments, AKS node resource groups, managed applications): the owning resource group name plus \'-managed\'.')
func managedResourceGroupName(resourceGroupName string) string => '${resourceGroupName}-managed'

@export()
@description('Short hostname-style name constrained to a character budget, such as a 15-character Windows computer name.')
func shortName(prefix string, environmentName string, shortHash string, budget int) string =>
  '${prefix}-${take(normalizeEnvironment(environmentName), max(1, budget - length('${prefix}--${shortHash}')))}-${shortHash}'
