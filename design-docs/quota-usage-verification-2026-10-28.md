# Quota and usage CLI verification — 0.1.8

Implemented service-independent quota inspection, timestamped usage queries, and
consumer override creation/update/deletion through public Google APIs. Reuses
existing authentication selection and the reader/writer/deleter role boundaries.

## Live checks (2026-10-28 JST)

- Service Gateway confirmed `youtube.googleapis.com` was already enabled in the
  existing `tacogips-service-auth-261001` project. Enabling it again would not
  resolve `quotaExceeded`.
- New reader returned full quota limits for YouTube, Gmail, and Service Usage.
  YouTube's default daily bucket is 10,000 units, with no consumer override.
- New reader listed consumer overrides for a Service Usage quota limit.
- New writer created a consumer override for Service Usage's
  `list_available_requests` per-project minute limit at its existing effective
  value, 60. It then updated the override to the same value.
- Both mutation operations completed. New deleter removed that override, and the
  reader verified the original empty override list. The effective quota was never
  reduced or increased during this roundtrip.
- Monitoring was initially disabled. Enabled it through the existing writer,
  without browser use, and observed the completed enable operation.
- Real usage requests for rate, allocation, exceeded, and requests then returned
  HTTP 403 with Google's explicit billing-required error. This project has billing
  disabled; no billing association was made without authorization. Successful
  live time-series retrieval remains unverified on this project.
- Found and fixed two pre-existing billing discovery errors: an empty
  `masterBillingAccount` is valid for top-level accounts, and a project number must
  resolve to its exact project ID before validating a Billing API response. Live
  billing account listing and numeric-project billing discovery now succeed.

## Tests and release checks

- Focused quota and billing regression tests cover wire paths, real service
  identifiers, exact project identity, encoded resource preservation, INT64
  precision, pagination and cycles, partial responses, role restrictions,
  authentication conflicts, provider errors/redaction, and override operation
  completion.
- Full `swift test` passed after the final version/help updates (132 tests).
- New quota and billing regression files pass strict SwiftLint. Whole-repository
  strict lint has the same 60 violations as the original commit. A separate
  checkout of its tracked Swift files and configuration confirmed zero new lint
  violation signatures. This is not reported as a clean whole-repository lint.

Official contracts:

Release follow-up: Linux CI still used Swift 6.1.3 from before the 0.1.7
`swift-crypto` upgrade. Its dependency resolution failed because Crypto 5.x
requires tools 6.2. Updated CI to the verified official Swift 6.3.3-noble image,
pinned by OCI digest, and documented the source-build prerequisite. This changes
the CI toolchain only, not the 0.1.8 macOS binary payloads.

- https://docs.cloud.google.com/service-usage/docs/reference/rest/v1beta1/services.consumerQuotaMetrics/list
- https://docs.cloud.google.com/service-usage/docs/reference/rest/v1beta1/services.consumerQuotaMetrics.limits.consumerOverrides/create
- https://docs.cloud.google.com/service-usage/docs/reference/rest/v1beta1/services.consumerQuotaMetrics.limits.consumerOverrides/patch
- https://docs.cloud.google.com/service-usage/docs/reference/rest/v1beta1/services.consumerQuotaMetrics.limits.consumerOverrides/delete
- https://docs.cloud.google.com/monitoring/api/ref_v3/rest/v3/projects.timeSeries/list
