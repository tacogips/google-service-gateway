# Google Ads and Google Cloud Control-Plane Boundary

## Status

Proposed

The billing boundary is implemented: reader billing discovery, writer rejection
of billing attachment, and signed single-use admin billing link/unlink plans.
IAM, service-account, hierarchy, service-identity, quota, and handoff-artifact
implementation remains phased work below.

## Decision

Keep Google Ads resources in `google-marketing-gateway`. Extend
`google-service-gateway` only for Google Cloud resource-hierarchy and identity
operations that have supported public APIs. Add a separate
`google-service-gateway-admin` executable for high-impact IAM, billing, service
identity, and hierarchy mutations rather than placing those operations in the
existing writer.

Higher Google Cloud privileges do not bypass Google Ads API access levels,
manager eligibility, billing setup, account status, or policy review. The two
gateways may form an onboarding workflow, but neither gateway is an arbitrary
Google REST proxy and neither may impersonate the other capability.

## Goals

- Give each operation one clear owner.
- Automate supported Google Cloud prerequisites for Google Ads and other Google
  APIs.
- Keep high-impact authorization mutations out of the routine writer.
- Preserve the existing reader, writer, deleter, and auth separation.
- Make every high-impact apply operation reviewable, bounded, and
  concurrency-safe.

## Non-goals

- Circumventing Google Ads developer-token review or permissible-use policy.
- Automating payment instruments, identity verification, or account
  reactivation through undocumented endpoints or browser scripting.
- Providing a generic URL, method, headers, or JSON escape hatch.
- Creating a Google Workspace or Cloud Identity tenant.
- Creating a Google Cloud organization resource directly. Google provisions
  that resource from Workspace, Cloud Identity, or supported standalone
  onboarding.
- Creating general OAuth clients or consent screens through undocumented APIs.
- Issuing user-managed service-account private keys in the initial admin slice.

## Ownership Matrix

| Operation | Owner | Public API support | Notes |
| --- | --- | --- | --- |
| Create Google Ads client account | marketing admin | Yes, conditional | `CustomerService.CreateCustomerClient`; manager must satisfy Ads eligibility and API access requirements. |
| Link an existing Ads client to a manager | marketing admin | Yes, conditional | Uses Ads manager-link services; requires access to both sides and an approved developer token/permissible use. |
| Generate keyword ideas | marketing reader | Yes, conditional | `KeywordPlanIdeaService.GenerateKeywordIdeas`; no mutation, but developer-token access still applies. |
| Create budgets, campaigns, ad groups, ads, and criteria | marketing writer | Yes | Routine Ads mutations; physical removes remain exclusive to marketing deleter. |
| Read serving and policy status | marketing reader | Yes | Read back resources and delivery metrics without mutation. |
| Reactivate a cancelled Ads account | Manual Google Ads UI | No usable Ads API path | Google states cancelled accounts are inaccessible through the Ads API until reactivated. |
| Configure Ads payment method or advertiser verification | Manual Google Ads/Payments UI | No supported management API | Financial and identity-verification workflow. |
| Apply for or upgrade an Ads developer token | Manual API Center and Google review | No | Policy application and review, not a Cloud IAM permission. |
| Create a Google Cloud project | service writer | Yes | Already implemented with Resource Manager v3. |
| Enable Google Ads API or another Google API | service writer | Yes | Already implemented with Service Usage v1. |
| Attach an existing Cloud Billing account to a project | service admin | Yes | Currently part of project provisioning; migrate the apply authority to admin because it changes the charging boundary. |
| Create a Cloud Billing subaccount | Deferred service admin | Limited | Public API exists for eligible billing-account administrators and reseller scenarios; it is not the same as creating a new primary billing account or payment profile. |
| Create or discover a Cloud organization | Manual provisioning, then service reader | Partial | Organization search/read is API-supported; acquisition is provisioned through Workspace, Cloud Identity, or supported standalone onboarding. |
| Create folders or move projects | service admin | Yes | High-impact hierarchy changes; exact source and destination confirmation required. |
| Read IAM policies and test permissions | service reader | Yes | Project, folder, and organization resources where supported. |
| Change project, folder, or organization IAM allow policy | service admin | Yes | Always plan first and apply with the provider `etag`. |
| Create, disable, enable, or update a service account | service admin | Yes | Deletion and undelete belong to service deleter. |
| Create a user-managed service-account key | Excluded initially | Yes, but intentionally disabled | Prefer user OAuth, workload identity federation, or attached service identities. Add only after a separate threat review. |
| Generate a Google-managed service identity | service admin | Yes, beta endpoint | Explicitly requested per service; returns a long-running operation. |
| Read consumer quota | service reader | Yes, beta endpoint | Treat provider resource names as opaque. |
| Apply consumer/admin quota overrides | Deferred service admin | Yes, beta endpoint | Provider- and ancestor-dependent. A higher requested quota can still require provider approval. |
| Create OAuth desktop client or edit consent configuration | Manual Console plus service auth import | No supported general mutation API | Keep the existing assisted Console workflow and secure import. |

## Proposed Product Boundary

### `google-service-gateway-reader`

Add only non-mutating discovery:

- `organizations search|get`
- `folders list|get`
- `projects get|list|search`
- `iam policy get --resource ...`
- `iam permissions test --resource ...`
- `service-accounts list|get`
- `billing accounts list|get`
- `billing projects get`
- `service-identities operation get`
- `quotas metrics list|get`

The reader must never construct a mutation request.

### `google-service-gateway-writer`

Retain routine project and API configuration:

- project creation and metadata updates;
- API enable, disable, and batch enable;
- non-deleting API-key creation and restriction.

Project creation does not accept or apply billing configuration. An onboarding
orchestrator must preserve the successful project-creation receipt and invoke a
separate admin billing plan. Service enablement remains a separate writer
operation when billing is a prerequisite, so failure in one phase never makes
the result of another phase ambiguous.

### `google-service-gateway-admin`

Add a new executable and adapter for bounded privileged mutations:

- `iam policy plan|apply` for project, folder, and organization allow policies;
- `billing projects link plan|apply` and `billing projects unlink plan|apply`;
- `service-accounts create|update|disable|enable`;
- `service-identities generate plan|apply`;
- `folders create|move plan|apply` and `projects move plan|apply`;
- a later, separately approved quota-override slice.

The initial implementation must not expose custom origins, arbitrary HTTP
methods, arbitrary IAM policy JSON replacement, organization policy mutation,
deny-policy mutation, billing-account creation, or service-account key
creation.

### `google-service-gateway-deleter`

Remain the exclusive owner of physical resource lifecycle removal and recovery:

- project delete and undelete;
- API-key delete and undelete;
- service-account delete and undelete when implemented;
- service-account-key delete if key management is ever approved.

Removing a principal from an IAM allow policy is an authorization-policy edit,
not physical resource deletion, and therefore remains an admin operation.

### `google-service-gateway-auth`

Retain OAuth setup assistance, secure client import, PKCE authorization,
refresh, and revocation. It must not claim to create an OAuth client or consent
screen through an unsupported public API.

## Admin Safety Contract

Every admin mutation uses a two-phase contract:

1. `plan` validates typed input, performs only the minimum reads needed to
   resolve current state, and writes canonical JSON containing a schema version,
   random plan ID, target, current state fingerprint, proposed delta, credential
   selector, required permissions, warnings, creation time, expiry time, digest,
   and HMAC signature. The signing key is loaded only from a named environment
   variable or secure store and is never included in the plan.
2. `apply` accepts only that plan, verifies the keyed signature, digest, schema,
   operation, credential binding, and expiry, re-reads the target, checks the
   provider concurrency token such as IAM `etag`, and requires exact confirmation
   of the resource and dangerous delta.
3. Immediately before the provider mutation, `apply` atomically consumes the
   plan ID in owner-only durable state. A consumed plan is never retried. An
   ambiguous provider outcome requires explicit read-based reconciliation and a
   newly issued plan.

Additional requirements:

- Fixed official HTTPS origins in production code.
- Resource-specific typed models and allowlisted fields.
- Reject wildcard principals, `allUsers`, and `allAuthenticatedUsers` by
  default.
- Reject `roles/owner` and primitive `roles/editor` grants by default; any
  future override needs a separate explicit policy and confirmation.
- Preserve conditional IAM bindings losslessly and require IAM policy version
  3 when conditions are present.
- Implement IAM changes as a fresh read-modify-write of the complete provider
  policy even though callers specify only a binding delta. Preserve `auditConfigs`,
  version, conditions, and all supported provider fields, and define the exact
  `updateMask` per resource type.
- Use `etag` compare-and-set semantics; never retry a failed IAM write with a
  refreshed policy automatically.
- Keep bearer tokens, OAuth client secrets, refresh tokens, private keys, and
  key material out of plans, stdout, logs, and error details.
- Load credentials by profile or environment-variable name. CLI arguments must
  never accept credential values.
- Store refresh credentials and any approved sensitive material through the
  existing secure-store abstraction.
- Bind every plan to an admin-specific OAuth profile or access-token environment
  selector. Executable separation is defense in depth; the selected Google IAM
  principal and its permissions remain the actual authorization boundary.
- Emit a stable JSON audit result containing actor profile name, target,
  operation, plan digest, provider request identifier when available, and
  before/after fingerprints, but no secrets.

## Cross-Gateway Google Ads Onboarding

The gateways coordinate through explicit artifacts, not shared credentials:

1. Service reader discovers the organization, folder, billing account
   visibility, and caller permissions.
2. Service writer creates the Cloud project and enables
   `googleads.googleapis.com` plus required authentication APIs.
3. Service admin attaches an existing billing account only if the chosen APIs
   require Cloud billing, and grants narrowly scoped project access.
4. Service auth guides the user through supported OAuth client creation and
   imports the client securely, then completes user authorization.
5. A human obtains or upgrades the Ads developer token in the Google Ads API
   Center and completes any review, payment, verification, or reactivation.
6. Marketing admin creates or links the Ads client account.
7. Marketing reader generates keyword ideas; marketing writer creates the
   bounded budget, campaign, ad group, ad, and criteria.
8. Marketing reader verifies resource state, policy review, and serving.
9. Marketing deleter alone performs physical Ads removes when explicitly
   requested.

The handoff artifact is versioned canonical JSON containing its schema version,
producer gateway and version, intended consumer, creation and expiry times,
Cloud project ID/number, manager customer ID, client customer ID, OAuth profile
name, requested scopes, and expected API services. Consumers reject unknown
major versions and ignore documented additive fields in the same major version.
The artifact is informational unless it carries a separately defined keyed
signature; it never grants apply authority. It must contain neither access nor
refresh tokens, developer-token values, client secrets, payment data, nor
service-account private keys.

## Implementation Phases

### Phase 1: Project IAM and service accounts

- Add the admin product and capability parser.
- Add reader IAM policy and permission inspection.
- Implement project IAM binding-delta plan/apply with `etag`.
- Implement service-account list/get/create/update/disable/enable.
- Map service-account metadata updates to the supported `patch` method rather
  than the deprecated whole-resource `update` method.
- Add service-account delete/undelete only to deleter.
- Keep user-managed key creation unavailable.

### Phase 2: Billing and hierarchy

- Separate billing association from routine project creation apply authority.
- Add billing account and project-billing reads to reader.
- Add billing link/unlink plan/apply to admin.
- Add organization/folder reads.
- Add folder creation and project/folder move plans with exact source and
  destination confirmation.

### Phase 3: Service identities and quotas

- Add `generateServiceIdentity` with operation polling.
- Add quota read APIs.
- Reassess beta quota override APIs, provider constraints, and recovery before
  exposing mutations.

## Verification Plan

Deterministic tests must assert complete outbound requests, fixed origins,
scope selection, validation-before-network behavior, secret redaction,
conditional-binding preservation, stale-`etag` rejection, plan digest/expiry
checks, and capability separation. Negative tests must prove that writer cannot
call admin or deleter endpoints and admin cannot call physical delete methods.

Live verification must use a disposable project and a dedicated low-privilege
principal:

1. Read the project IAM policy and caller permissions.
2. Generate a plan granting one narrow test role to the test principal.
3. Apply it and read back the exact binding.
4. Generate and apply a plan removing only that binding.
5. Create a service account, disable it, enable it, and read back each state.
6. Delete and undelete the test service account through deleter if the provider
   supports recovery for the tested resource state.
7. Generate one supported Google-managed service identity and inspect the
   completed operation.

Do not test organization-owner grants, billing unlink on a production project,
quota increases, primary billing-account creation, payment methods, or
user-managed private-key issuance as part of routine verification.

For Google Ads, the already implemented marketing commands are verified in two
layers: deterministic tests for request construction and live calls after the
developer token has the required production access and permissible uses.
`DEVELOPER_TOKEN_NOT_APPROVED` is an external approval blocker, not evidence
that a higher Cloud IAM credential should be used.

## Provider Evidence

- Google Ads account creation uses `CreateCustomerClient` and is limited to
  eligible advertisers: <https://developers.google.com/google-ads/api/docs/account-management/create-account>
- Google Ads access levels and permissible uses are developer-token policy:
  <https://developers.google.com/google-ads/api/docs/api-policy/access-levels>
- Cancelled Ads accounts are inaccessible through the Ads API until manually
  reactivated: <https://support.google.com/google-ads/answer/7619129>
- Resource Manager exposes project, folder, and organization IAM operations:
  <https://cloud.google.com/resource-manager/reference/rest>
- IAM exposes service-account lifecycle methods:
  <https://cloud.google.com/iam/docs/reference/rest>
- Service Usage exposes `generateServiceIdentity` and quota resources:
  <https://cloud.google.com/service-usage/docs/reference/rest>
- Cloud Billing can associate a project with an existing billing account:
  <https://cloud.google.com/billing/v1/requests>
- Google documents OAuth client creation as a Console workflow:
  <https://developers.google.com/identity/protocols/oauth2/native-app>
- Google Cloud organization acquisition is provisioned through Workspace,
  Cloud Identity, or supported standalone onboarding:
  <https://cloud.google.com/resource-manager/docs/creating-managing-organization>

## Open Decisions Before Implementation

- Which narrow roles are allowed by default for IAM binding plans.
- Whether folder creation and moves are needed before project IAM.
- Whether service-account delete recovery semantics meet the deleter contract
  across the supported API version.
- Whether any quota-override use case justifies depending on the beta API.
- Whether the organization-level Google Ads cloud-managed access pilot is
  available and appropriate after the current developer token is approved; it
  does not replace the initial Ads review.
