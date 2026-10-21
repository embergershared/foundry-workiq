# Repository overview

This repository is a reusable, infrastructure-only Azure PoC starter and an
installed Squad workspace. Azure Developer CLI (`azd`) orchestrates
subscription-scope modular Bicep from `azure.yaml`; there is no application
source yet. The Squad team in `.squad/team.md` is already cast and is inherited
by repositories created from this template.

The approved deployment contract is `.azure/deployment-plan.md`. User guidance
starts in `README.md` and `docs/`. Keep implementation, documentation, and the
plan synchronized.

## Engineering standards

Apply these standards when application or infrastructure code is added. They
adapt the current
[Awesome Copilot Azure Developer CLI](https://github.com/github/awesome-copilot/tree/main/skills/azure-developer-cli),
[security and OWASP](https://github.com/github/awesome-copilot/blob/main/instructions/security-and-owasp.instructions.md),
[Python](https://github.com/github/awesome-copilot/blob/main/skills/python-mcp-server-generator/SKILL.md),
[C#](https://github.com/github/awesome-copilot/blob/main/instructions/csharp.instructions.md),
and [.NET architecture](https://github.com/github/awesome-copilot/blob/main/instructions/dotnet-architecture-good-practices.instructions.md)
guidance.

### Azure deployment

- Use Azure Developer CLI (`azd`) as the deployment orchestrator. Model
  deployable services in a root `azure.yaml`, keep IaC under `infra/`, and
  default to modular Bicep unless the repository or user explicitly chooses
  Terraform. Do not replace an established IaC provider or hosting service
  without an explicit architectural decision.
- Before any cloud-changing command, verify the AZD environment, subscription,
  tenant, region, and scope. Run existing application checks, IaC validation,
  `azd package`, and `azd provision --preview -e <environment>` before
  `azd up -e <environment>`. Use separate `azd provision` and `azd deploy`
  phases when review, approvals, or troubleshooting require that separation.
- Keep environment-specific values parameterized. Commit only the approved
  `.azure/deployment-plan.md`; exclude azd environment state, `.env` files,
  credentials, local Terraform state, and generated deployment artifacts from
  source control. Use `azd env set` and `azd env set-secret` rather than editing
  environment files.
- After deployment, verify resource state and smoke-test every returned
  endpoint. Never report deployment success from command exit alone.
- Follow the gated lifecycle: `azure-prepare` updates the plan and IaC,
  `azure-validate` proves policy, quota, syntax, dependency, and preview checks,
  and `azure-deploy` changes Azure only after explicit approval. Do not collapse
  these phases.
- Preserve the `minimal` and `full` profiles and validate expert overrides.
  Full-profile Entra VM login depends on NAT. An air-gapped override must set
  both `natGateway` and `entraLogin` to `false`.

### Security

- Treat security defects as blocking. Review against the current OWASP Top 10
  and validate untrusted data at every trust boundary. Use parameterized
  queries, context-appropriate output encoding, explicit authentication and
  authorization, secure defaults, and allowlists where practical.
- Prefer managed identity with least-privilege RBAC for Azure workloads,
  workload identity federation/OIDC for CI/CD, and Key Vault references when a
  secret is unavoidable. Never hardcode, commit, echo, log, expose in IaC
  outputs, or pass secrets through command lines that may be recorded.
- Use established platform cryptography and security libraries; never implement
  custom cryptographic algorithms. Keep dependencies minimal, pinned or locked,
  and checked for known vulnerabilities. Do not expose verbose errors, stack
  traces, or sensitive data to clients.

### Python

- Target the latest stable Python version supported by the project's
  dependencies. Respect an existing `requires-python`, lock file, and tool
  configuration; do not silently change the supported runtime.
- Follow PEP 8 and existing formatter/linter configuration. Require type hints
  on public APIs and function parameters/returns, precise data models for
  structured data, and docstrings on public or non-obvious interfaces.
- Use `pathlib`, context managers for resource lifetime, `async`/`await` for
  I/O-bound concurrency, and specific exception types. Do not use mutable
  default arguments, bare `except`, swallowed exceptions, wildcard imports, or
  unvalidated external input.
- Keep modules and functions focused and independently testable. Use the
  repository's existing test framework and cover normal, boundary, and failure
  paths; do not introduce a new formatter, linter, package manager, or test
  runner when the project already has one.

### C# and .NET

- Use the latest stable LTS .NET SDK and the latest C# language version it
  supports for new projects. Respect existing `global.json`, target frameworks,
  nullable settings, `.editorconfig`, and repository conventions; upgrades must
  be explicit rather than incidental.
- Enable nullable reference types. Prefer non-nullable models, validate at entry
  points, use `is null`/`is not null`, use `async`/`await` for I/O, pass
  `CancellationToken` through asynchronous boundaries, and use built-in
  dependency injection and structured logging.
- Follow standard C# naming, file-scoped namespaces where consistent, pattern
  matching where it improves clarity, `nameof` for member names, and XML
  documentation for public APIs. Use explicit, centralized exception handling
  and RFC 9457 Problem Details for HTTP API errors.
- Apply Clean Architecture with inward-only dependencies:
  `Presentation -> Application -> Domain`, while `Infrastructure` implements
  interfaces owned by the inner layers and is wired at the composition root.
  The Domain layer contains business rules and has no dependency on
  persistence, HTTP, Azure SDKs, or framework infrastructure. Application
  contains use cases and ports; Infrastructure contains adapters; Presentation
  translates transport concerns. Do not add repository abstractions over EF
  Core unless they protect an actual domain boundary or provide testable value.

### Architecture and code quality

- Preserve separation of concerns, high cohesion, loose coupling, and dependency
  inversion. Business policy must not depend on UI, transport, persistence, or
  cloud implementation details. Follow established repository patterns before
  introducing new abstractions.
- Prefer the simplest design that completely satisfies the requirement. Keep
  functions/classes focused, remove meaningful duplication, make contracts and
  invariants explicit, and avoid speculative layers, generic frameworks, and
  service-locator patterns.
- Fail fast at boundaries with actionable errors; never convert failure into a
  success-shaped fallback. Maintain backward compatibility for public contracts
  unless a breaking change is intentional and documented.
- Validate architecture as part of implementation and review: check dependency
  direction, security boundaries, error handling, resource cleanup,
  concurrency, performance-sensitive data access, and tests for critical paths.

### Mandatory plan quality

Before implementation or cloud changes:

1. Clarify material ambiguity; do not silently guess about scope, identity,
   exposure, data sensitivity, recovery, region, budget, or destructive action.
2. List assumptions and actively challenge their security, cost, operability,
   policy, quota, licensing, and failure-mode consequences.
3. Obtain an independent rubber-duck review from another reviewer/agent when
   the client supports it. Record findings and dispositions in the plan.
4. When independent review is unavailable, use this checklist and record the
   result: trust boundaries; public surfaces; least privilege; secret lifecycle;
   dependencies; rollback/recovery; observability; recurring/idle cost; quota
   and policy; licensing; destructive cleanup; validation evidence.
5. Keep unresolved material risks visible and stop before an irreversible or
   cloud-changing action when they prevent safe execution.

## Validation commands

This infrastructure-only repository has no application test target. Do not run
the `npm test` commands mentioned inside installed Squad skills or template
comments; they belong to the upstream Squad CLI/SDK source repositories.

Use the checks that apply to the files changed:

```powershell
# Parse every JSON file.
Get-ChildItem -Recurse -Filter *.json |
  ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json | Out-Null }

# Validate infrastructure without changing Azure.
az bicep build --file infra\main.bicep
az bicep lint --file infra\main.bicep
azd provision --preview -e <environment>
```

Parse PowerShell with its AST before running changed scripts. The infrastructure
workflow is `.github/workflows/infra-validation.yml`; the live Squad
automations remain separate.

## Architecture

- `.github/agents/squad.agent.md` is the installed coordinator prompt. It
  resolves the state backend and team root, selects Init Mode or Team Mode, and
  dispatches work. The final `SQUAD_COORDINATOR_CANARY_a8f3` token detects a
  truncated prompt.
- `.squad/` is the project team layer. `team.md`, `routing.md`,
  `ceremonies.md`, `decisions.md`, agent charters, and RAI policy are project
  configuration/state. With the minimal `.squad/config.json` in this repository,
  unspecified state settings use the coordinator's local defaults.
- `.squad/templates/` is an installed snapshot of Squad-owned templates and
  references. It is input/reference material for initialization and upgrade,
  not this repository's application source. `.copilot/skills/` contains the
  installed focused guidance used by Copilot sessions.
- `.copilot/mcp-config.json` configures the `squad_state` MCP bridge through
  `@bradygaster/squad-cli@insider`. The root `.mcp.json` contains an
  `EXAMPLE-github` placeholder and must not be treated as a working GitHub MCP
  configuration.
- The issue automation is a pipeline: `sync-squad-labels.yml` parses the roster
  into `squad:*` labels; `squad-triage.yml` reacts to the base `squad` label and
  chooses a member; `squad-issue-assign.yml` reacts to a member label and
  acknowledges or assigns the work; `squad-heartbeat.yml` runs the standalone
  `.squad/templates/ralph-triage.js` monitor after issue/PR activity.

## Repository conventions

- Preserve the exact `## Members` heading and Markdown roster-table shape in
  `.squad/team.md`. Multiple workflows parse that section line-by-line; changing
  the heading or replacing the table breaks labels and routing. Replace the
  placeholder rows in `.squad/routing.md` when casting the team.
- Treat `.squad/templates/**`, `.github/agents/squad.agent.md`, and the installed
  workflow set as Squad-owned artifacts that `squad upgrade` may overwrite.
  The four active workflow files currently match their counterparts under
  `.squad/templates/workflows/`; keep those local pairs synchronized when an
  intentional customization is required.
- Project-owned team state is different from installed templates. Preserve
  edits to `.squad/team.md`, `.squad/routing.md`, `.squad/ceremonies.md`, and
  `.squad/decisions.md` across upgrades.
- Files covered by `.gitattributes` use the union merge driver because they are
  append-only team state. Append to decisions, agent histories, logs,
  orchestration logs, and the RAI audit trail; do not rewrite or reorder them.
  Runtime inboxes, logs, sessions, scratch data, and caches listed in
  `.gitignore` remain local.
- Decisions affecting other agents go to
  `.squad/decisions/inbox/<agent>-<brief-slug>.md` for Scribe to merge. That
  inbox is intentionally ignored rather than committed directly.
- Never read live `.env` or `.env.*` files. Use `.env.example`, `.env.sample`,
  or `.env.template` for schema information. Never write credentials, tokens,
  connection strings, private keys, email addresses, or other PII into
  committed `.squad/` state.
- For Squad issue work, use `squad/<issue-number>-<kebab-case-slug>` branches,
  reference the issue with `Closes #<number>`, and follow decisions recorded in
  `.squad/decisions.md`. This repository currently has only `main`; do not apply
  the upstream Squad CLI skill's `dev`/`insiders` branch model here.
