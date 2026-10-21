# Deployment plan

This is the project's deployment contract. `azure-prepare` fills it in,
`azure-validate` records evidence against it, and `azure-deploy` changes Azure
only after the approval below is recorded. Keep it aligned with `README.md`,
`docs/`, `azure.yaml`, the hooks and the Bicep.

Status: **Not prepared. No environment selected; nothing validated or deployed.**

## Target

| Item | Value |
|---|---|
| azd environment | `<environment>` |
| Tenant | `<tenant name>` (`<tenant-guid>`), listed in `infra/core/tenant-codes.json` |
| Subscription | `<subscription name>` (`<subscription-guid>`), code `s<N>` |
| Region | `<region>` (`<location code>`) |
| Deployment profile | `core` / `private` / `full` |
| Feature overrides | `{}` |
| Catalog modules | `<modules this project composes beyond the profile>` |

## Decisions

Record each decision with its date, who approved it, and the alternatives and
consequences considered. A later decision supersedes an earlier one explicitly;
do not rewrite history.

- `<yyyy-mm-dd>`: `<decision>`

## Public exceptions and risks

- `<resource>`: `<why it is public, and the controls that apply>`

## Validation checklist

All checks must pass before a deployment. A passing PR or offline test run does
not waive any of them.

- [ ] Verify the AZD installation and the `azure.yaml` schema.
- [ ] Confirm the environment, tenant, subscription, region and scope.
- [ ] Verify authentication, providers, quota, licensing and permissions.
- [ ] Run `./tests/run-tests.ps1`.
- [ ] Run preflight and `azd provision --preview -e <environment>`.
- [ ] Repeat Bicep build/lint and validate packaging with `azd package`.
- [ ] Review effective Azure policy and static RBAC.
- [ ] Record the environment-specific evidence below.

## Approval

- `<yyyy-mm-dd>`: `<approver>` approved `<operation>` for `<environment>`.

## Evidence

Record each validation or deployment run: the date, the environment, the
commands run, and the result. Never record secrets or `.env` contents.
