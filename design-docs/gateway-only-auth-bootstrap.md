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
