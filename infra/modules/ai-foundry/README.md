# ai-foundry

Microsoft Foundry (AIServices) account with local auth disabled, a Foundry project and serialized model deployments.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `aif`, `proj` |
| Providers | `Microsoft.CognitiveServices` |
| Private endpoints | – |
| Feature flag | `aiFoundry` |
| Name rule | `global` for the account (custom subdomain, 64-character budget); `regional` with `proj` for the project |

## Purpose

A Microsoft Foundry (AIServices) account with key authentication disabled, a Foundry project for agents, and model deployments. Operations on one account conflict when they overlap, so the project is created first and deployments run one at a time.

Grant workloads `Cognitive Services OpenAI User` on the account for chat and Realtime, and `Azure AI User` (Foundry User) on the project to run agents.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Also the custom subdomain |
| `location` | string | no | Pick a region with model availability and quota |
| `tags` | object | no |  |
| `projectName` | string | yes |  |
| `projectDisplayName` | string | no |  |
| `deployments` | array | no | `[{ name, model, version, sku?, capacity }]`; `sku` defaults to `GlobalStandard` |
| `publicNetworkAccess` | string | no | Default `Enabled` |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `openAiEndpoint` |  |
| `projectId` |  |
| `projectName` |  |
| `projectEndpoint` |  |

## Wire-up

```bicep
module aiFoundry 'modules/ai-foundry/main.bicep' = {
  scope: resourceGroup
  name: 'ai-foundry'
  params: {
    name: globalName(abbreviations.aiFoundry, aiLocationCode, subscriptionCode, environmentName, shortUniqueSuffix, '-', 64)
    projectName: azName(abbreviations.aiFoundryProject, tenantCode, aiLocationCode, subscriptionCode, environmentName, '')
    location: aiLocation
    tags: tags
    deployments: [
      { name: 'chat', model: 'gpt-5.4', version: '2026-03-05', capacity: 50 }
    ]
  }
}
```
