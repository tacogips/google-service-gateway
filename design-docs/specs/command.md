# Command

## Status

Approved for implementation

## Shared Options

Both executables support:

```text
--project <id|number|projects/id-or-number>
--access-token-env <environment-variable-name>
--pretty
--help
--version
```

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

Disable does not disable dependent services unless `--disable-dependents` is
present. It skips Google's recent-usage check unless `--check-usage` is
present. The API can reject disabling an already-disabled service or a service
with enabled dependents; those failures retain Google's safe status and message
in the stable error envelope.

Unknown commands, including `list`, `get`, and operation administration, fail
before transport execution. Internal `operations.get` polling is the writer's
only read request.

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
