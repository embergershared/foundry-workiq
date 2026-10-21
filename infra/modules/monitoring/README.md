# monitoring

Log Analytics workspace plus a workspace-based Application Insights component.

| | |
|---|---|
| Kind | `composite` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `law` (workspace), `appins` (Application Insights) |
| Providers | `Microsoft.OperationalInsights`, `Microsoft.Insights` |
| Private endpoint | none |
| Feature flag | none — always deployed |

## Purpose

This module *is* the `core` rung. Every profile deploys it, so every project
built from this template has telemetry from the first deployment without opting
in to anything.

A daily ingestion cap keeps an idle proof of concept effectively free.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Log Analytics workspace name |
| `location` | string | no | Defaults to the resource group location |
| `tags` | object | no | Common tags from `infra/core/tags.bicep` |
| `applicationInsightsName` | string | yes | Application Insights component name |
| `retentionInDays` | int | no | Default `30` |
| `dailyCapGb` | int | no | Default `1` |

## Outputs

| Name | Notes |
|---|---|
| `logAnalyticsWorkspaceId` | Wire into every module that emits diagnostics |
| `applicationInsightsId` | |
| `applicationInsightsName` | |

## Wire-up

```bicep
module monitoring 'modules/monitoring/main.bicep' = {
  scope: resourceGroup
  name: 'monitoring'
  params: {
    name: logAnalyticsName
    applicationInsightsName: applicationInsightsName
    location: location
    tags: tags
  }
}
```
