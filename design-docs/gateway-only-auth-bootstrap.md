# Gateway-only authentication bootstrap

## User decision

Use gcloud for initial Cloud authentication, then use Service gateway to create
projects and enable APIs. Each gateway should subsequently run provider-free
native OAuth login without depending on gcloud. Do not use computer automation
for Cloud project setup. The user subsequently authorized Brave Computer Use for
Google login consent; new or broader access requires action-time confirmation.

Nine bootstrap projects created on 2026-09-30 were deleted at the user's request.
All were confirmed in `DELETE_REQUESTED` state. Replacement creation is recorded
in the 2026-10-01 section below.
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

The earlier bootstrap shared-library revision was
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
not resolved by the existing-client tests. Replacement projects are recorded
below; their Google-side OAuth clients are still absent.

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

## Live verification on 2026-10-01

Brave became accessible again. New Drive reader and writer native logins saved
refreshable private-file credentials. A Drive reader `about get` call succeeded.
Analytics writer native login and a `gaAccounts` API query also succeeded.

A live OCR login exposed an incremental-authorization defect: the Cloud OAuth
request included earlier Workspace grants, saved them, and incorrectly reported
READY even though the OCR API token provider requires exactly cloud-platform.
Service OAuth browser requests now set include_granted_scopes=false. OCR validates
the returned scope set before persistence and marks a saved incompatible scope
set INVALID. The unusable local OCR file was preserved in a private backup before
replacement login. The replacement grant contains only cloud-platform, and a
Document AI processor-list call succeeded without gcloud. A fresh Service grant
also contains only cloud-platform; listing all enabled services succeeded.
All 15 required API IDs are enabled in the existing ai-tools-proj project.

Service passed 118 Swift Testing functions; OCR passed 35; Gmail passed its full
Swift test suites after pinning the corrected Service SDK. All 28 commands again
passed 112 provider lifecycle checks using an injected fixture executable. These
fixture checks do not prove a real gcloud ADC grant.

The shared authentication revision is 13c40e2. Gmail and OCR pin Service
revision 6dc0261, which includes native scope isolation and the updated shared
provider implementation. Current patch artifacts must be rebuilt after these
fixes. Publication, tap metadata verification,
and mise-darwin installation remain incomplete.

Remaining live grants include Docs/Sheets, Analytics reader/admin, Marketing,
and Gmail mailbox roles. Docs reached its consent screen and timed out while
new-scope approval was pending. No grant is claimed for that attempt. The
pending confirmation requests the remaining permissions for the already
registered calendar-gateway OAuth application.

At the end of those native-login checks, no replacement gateway projects or
Google-side OAuth clients had been created.
The working logins use the existing registered client in ai-tools-proj. Local
clients register imports an already registered client; it is not Google-side
client registration. Live registered Web-client/public HTTPS callback validation
also remains unproven; those paths currently have local fixture coverage only.

## Completed real provider checks

Service and Drive reader subsequently completed real gcloud ADC browser login.
Both reported READY, and actual Service Usage and Drive reads succeeded. A real
Drive attempt first exposed gcloud's mandatory cloud-platform scope requirement;
the shared provider now includes that scope once in addition to the role's
scopes. Native OAuth retains the product's scopes without this provider-specific
addition. Calendar and Gmail role grants were aligned with native scopes, and
Drive writer requests drive.file rather than full Drive access.

Provider-free Service and Drive reader logins then succeeded, cleared each
selected gcloud provider binding, and passed actual API reads using private-file
native credentials. These paths no longer depend on gcloud after the native
login. No Keychain storage was used. The fixture executable now also rejects
login requests missing the mandatory Cloud scope; all 112 lifecycle checks pass.

Analytics binary tests now isolate both configuration and credential state so
negative authentication checks cannot consume live user credentials. The Docs
inline credential deadline fixture allows decoder entry under full-suite load;
its tests were moved to a separate file to keep Swift files below 1000 lines.

## Replacement projects created through Service gateway on 2026-10-01

The existing gcloud login supplied an ephemeral access token to Service gateway's
writer. All nine projects were created by `projects create`; the same command
completed API enablement and operation polling. Each required API set was then
verified by `services list --state enabled --all-pages` with Service gateway's
native file credentials. No Cloud Console or browser automation was used for
project creation or API enablement. No billing account was linked.

Authoritative command results are in `gateway-auth-projects-2026-10-01.json`.
All nine create commands and verification reads returned exit 0. Each returned
project has state ACTIVE, and every required API is present in the enabled list.

| Product | Project ID | Required APIs enabled |
| --- | --- | --- |
| Service | tacogips-service-auth-261001 | Cloud Resource Manager, Service Usage, Cloud Billing, API Keys |
| Calendar | tacogips-calendar-auth-261001 | Calendar |
| Gmail | tacogips-gmail-auth-261001 | Gmail |
| Docs | tacogips-docs-auth-261001 | Docs, Drive |
| Sheets | tacogips-sheets-auth-261001 | Sheets, Drive |
| Drive | tacogips-drive-auth-261001 | Drive |
| Analytics | tacogips-analytics-auth-261001 | Analytics Admin, Analytics Data, Tag Manager |
| Marketing | tacogips-marketing-auth-261001 | Google Ads, AdSense, AdMob, Search Console |
| OCR | tacogips-ocr-auth-261001 | Document AI |

Project creation and API enablement are complete. These projects do not yet
have Google-registered OAuth clients or consent-screen configuration. Native
credentials currently verified still use the existing ai-tools-proj client;
they are not proof of native authentication through these replacement projects.
The gateway-only client-registration requirement remains unresolved. Google's
current instructions still describe Desktop/Web client creation in the Console:
https://docs.cloud.google.com/mcp/set-up-authentication-mcp-servers .
