# Gateway-only authentication bootstrap

## User decision

Use gcloud for initial Cloud authentication, then use Service gateway to create
projects and enable APIs. Each gateway should subsequently run provider-free
native OAuth login without depending on gcloud. Do not use computer automation.

Nine bootstrap projects created on 2026-09-30 were deleted at the user's request.
All were confirmed in `DELETE_REQUESTED` state. No replacements were created.
No Desktop OAuth client was created through the browser workflow.

## Implemented source changes

All 28 CLI composition roots integrate the shared GoogleGatewayAuth library.
`auth login --provider gcloud` uses an isolated gcloud ADC configuration. Cloud
Service roles share their selected Cloud profile; role-sensitive Workspace
credentials stay isolated. Explicit external inputs retain precedence.
Provider-free login discovers a private maintainer-installed default Desktop
client and uses the existing native OAuth flow, then clears an earlier gcloud
selection only after successful login. SDK credential behavior is preserved.

## Remaining registration dependency

Project creation and service enablement do not register an OAuth client or
configure Google Auth Platform consent. Google's Desktop-client documentation
requires Cloud Console setup. No supported Desktop registration API was found.
The IAM OAuth client resource is not a replacement for a Google Auth Platform
Desktop client. The IAP OAuth Admin API was restricted to IAP and was shut down
on March 19, 2026.

- https://developers.google.com/workspace/guides/create-credentials
- https://docs.cloud.google.com/mcp/set-up-authentication-mcp-servers
- https://docs.cloud.google.com/iap/docs/programmatic-oauth-clients
- https://docs.cloud.google.com/sdk/gcloud/reference/iam/oauth-clients/create

## Verification

All seven gateway repositories passed `git diff --check`, `swift build`,
`swift test`, and `mise exec -- swiftlint --quiet` against the shared integration.
Shared tests cover provider isolation, source precedence, scopes, default-client
selection, cancellation/failure, private storage, subprocess capture/timeout,
and switching to native authentication.

A real Service `auth login --provider gcloud` launched Google's browser consent
without computer use, but timed out before user consent completed. No successful
provider selection, direct gateway login, or live API grant is claimed by this
implementation verification. A project-creation/API-enablement-only workflow
cannot yet satisfy the complete requested native login acceptance requirement.

The final pinned shared-library revision is
`dda86daa5ca1b9a761977e4a9891e4e4380cf4dd` in `tacogips/google-gateway-auth`. All 28 debug executables passed 112
provider lifecycle checks (login/status/refresh/revoke) against an injected
fixture executable. These are subprocess integration checks, not real Google
consent or API permission checks. The shared package passed 14 tests and
`swiftlint lint --quiet` with no errors (one test-file whitespace warning).

## Existing-client discovery and live project identity fix

A preexisting Desktop client for `ai-tools-proj` was found locally in Downloads.
Its credential values were neither printed nor committed. Private local default
client files were installed for all nine namespaces for native-flow validation.
This does not create or relocate OAuth clients into gateway-specific projects.
The Service provider-free login started using this client but ended with
`OPERATION_TIMEOUT` before browser consent completed. No token grant is claimed.

A live Service Usage read exposed rejection of project-number response names
when the CLI was given a project ID. Service reads now resolve IDs through
Cloud Resource Manager, verify the returned project ID and number, and keep
exact service response identity checks. Numeric inputs retain the direct path.
Four new tests, including three malformed-identity cases, cover this behavior;
all 111 Service tests and lint pass. The live Service reader can now list the
enabled APIs in `ai-tools-proj` by project ID. That confirms the token supplied
from gcloud works for the Service read, not that native login has succeeded.

Client ownership (shared existing client versus one client per new project) is
pending user clarification. No replacement projects have been created.

## Native file-storage verification

Service native browser consent subsequently succeeded. The first API read was
blocked by a Keychain access prompt. At the user's request the default OAuth
vault now uses private local files, with no automatic Keychain access/migration.
A new login saved the refreshable native credential to that file store; a real
Service Usage list then succeeded using the native profile without gcloud.
The shared callback implementation supports configurable local listeners and
public HTTPS callback URIs for registered Web clients behind a TLS reverse proxy.
The local clients register command imports an existing registered Google client;
it does not implement Google-side client creation.
