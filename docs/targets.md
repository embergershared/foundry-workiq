# Deployment targets

The tenants and subscriptions this repository deploys to. This file and
`infra/core/tenant-codes.json` hold the owner's specifics; a repository created
from the template replaces both with their `.example` counterparts. See
[Starting a repository from the template](deployment.md#starting-a-repository-from-the-template).

The default target is tenant `dd045087-7959-4625-81a9-bf44022f1aa8`
(code `567410`) and subscription `MngEnv567410-s2-Sandbox`
(`113c3bf3-dff3-4bb7-84e8-2cd44152185e`).

| Tenant | Tenant ID | Code | Subscriptions |
|---|---|---|---|
| Contoso | `dd045087-7959-4625-81a9-bf44022f1aa8` | `567410` | `MngEnv567410-s1-Hub`, `MngEnv567410-s2-Sandbox` (default), `MngEnv567410-s3-Projects` |
| Caldova | `7fe93c78-6179-4890-9320-bbe36717e13b` | `68819187` | `Caldova-68819187-s1` (`5c6f5679-f43b-4d03-8a38-d4f2cf8d1bdc`, code `s1`) |

Every tenant in this table must be listed in `infra/core/tenant-codes.json`. To
add one, follow
[Deploy to another tenant or subscription](deployment.md#deploy-to-another-tenant-or-subscription).
