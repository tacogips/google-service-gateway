# Command

## Status

Approved for implementation

## Shared Options

Capability executables support the applicable subset of:

```text
--project <id|number|projects/id-or-number>
--access-token-env <environment-variable-name>
--service-account-env <environment-variable-name>
--pretty
--help
--version
```

`--service-account-env` selects an environment variable containing Google
service-account JSON. It is mutually exclusive with `--access-token-env` and
`--oauth-profile`; the private key and exchanged token are never included in
normal command output.

Project and token environment precedence and secret-handling rules are defined
in `architecture.md`. Command results follow its stable stdout, stderr, JSON,
and exit-status contract. `--project` applies to service commands. Reader
`operations get` requires only `--operation` plus token configuration; it
rejects an explicit `--project` and does not read either project environment
variable.

## Reader

The reader exposes no mutation command:

```bash
google-service-gateway-reader services list \
  [--state enabled|disabled|all] [--page-size 1...200] \
  [--page-token <token>] [--all-pages]

google-service-gateway-reader services get --service <alias|service-id>

google-service-gateway-reader operations get --operation <operations/name>

google-service-gateway-reader billing accounts list \
  [--page-size 1...100] [--page-token <token>]
google-service-gateway-reader billing accounts get \
  --billing-account <billingAccounts/id>
google-service-gateway-reader billing projects get --project <project>
google-service-gateway-reader iam permissions test --project <project> \
  --permission <iam.permission> [--permission <iam.permission> ...]
```

`services list` returns one page by default. `--all-pages` follows every page
and cannot be combined with `--page-token`. State `all` sends no filter. The
operation command accepts only the `operations/<id>` resource form returned by
Service Usage and cannot cancel or delete an operation.

Unknown commands, including `enable`, `disable`, and `batch-enable`, fail during
argument validation before project, token, or transport resolution.

## Writer

The writer exposes only mutations:

```bash
google-service-gateway-writer projects create \
  --project-id <globally-unique-id> --display-name <name> \
  [--parent <organizations/id|folders/id>] [--label <key=value> ...] \
  [--service <alias|service-id> ...] [--scope <alias-or-uri> ...] \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]

google-service-gateway-writer services enable --service <alias|service-id> \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]

google-service-gateway-writer services disable --service <alias|service-id> \
  [--disable-dependents] [--check-usage] \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]

google-service-gateway-writer services batch-enable \
  --service <alias|service-id> [--service <alias|service-id> ...] \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]
```

Waiting defaults to enabled, a 1-second poll interval, and a 120-second
timeout. Durations must be finite and positive. `--no-wait` cannot be combined
with polling options. Batch enable accepts 1 through 20 distinct services.
Project creation uses Cloud Resource Manager v3. Service enablement is an
optional post-creation step and requires waiting; `--no-wait` is valid only for
project creation without that post-step. Billing attachment is unavailable in
writer and belongs to signed plan/apply operations in the admin executable. The
result includes
resolved Google Auth Platform client and consent-screen Console handoffs.

Disable does not disable dependent services unless `--disable-dependents` is
present. It skips Google's recent-usage check unless `--check-usage` is
present. The API can reject disabling an already-disabled service or a service
with enabled dependents; those failures retain Google's safe status and message
in the stable error envelope.

Unknown commands, including `list`, `get`, and operation administration, fail
before transport execution. Delete and undelete commands are also rejected and
must use the deleter. Internal operation polling is the writer's only read
request.

## Admin

The initial admin slice exposes only Cloud Billing project association:

```bash
google-service-gateway-admin billing projects link plan \
  --project <project> --billing-account <billingAccounts/id> \
  [--expires-in <60...3600>]
google-service-gateway-admin billing projects link apply \
  --plan <regular-file> --state-dir <absolute-owner-only-directory> \
  --confirm-project <projects/id> --confirm-billing-account <billingAccounts/id>

google-service-gateway-admin billing projects unlink plan \
  --project <project> [--expires-in <60...3600>]
google-service-gateway-admin billing projects unlink apply \
  --plan <regular-file> --state-dir <absolute-owner-only-directory> \
  --confirm-project <projects/id> --confirm-billing-account <billingAccounts/id> \
  --confirm-unlink
```

Plans are canonical, HMAC-signed, credential-selector-bound, expiring, checked
against fresh provider state, and consumed atomically before mutation. The
signing key comes from the environment variable selected by `--plan-key-env`;
the default is `GOOGLE_SERVICE_GATEWAY_ADMIN_PLAN_KEY`. A plan signing key must
contain at least 32 UTF-8 bytes and is never accepted as a CLI value.

## Deleter

The deleter is the only executable that can delete or restore provider
resources:

```bash
google-service-gateway-deleter projects delete [--project <project>] \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]
google-service-gateway-deleter projects undelete [--project <project>] \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]
google-service-gateway-deleter api-keys delete --key <resource> \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]
google-service-gateway-deleter api-keys undelete --key <resource> \
  [--no-wait] [--poll-interval <seconds>] [--timeout <seconds>]
```

The writer rejects these commands before authentication or transport
resolution. Undelete stays paired with delete because it is the recovery path
for resources managed through this restricted capability.

## Examples

```bash
GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-reader services list \
  --project my-project --state enabled --all-pages

GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-reader services get \
  --project projects/123456789 --service sheets

GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-writer services batch-enable \
  --project my-project --service drive --service docs
```

Examples must never echo or print the token. Shell history guidance should
prefer injected environment tooling for persistent use; the examples show only
process-scoped environment assignment.

OAuth and API-key commands are specified in `oauth-and-api-keys.md`. Their
secret-output commands are deliberately separate from routine reader output.
