# Riela Node Integration

## Ownership boundary

`GoogleServiceGatewayCore` is the reusable Service Usage client. It does not
depend on Riela. The sibling Riela package imports the core product and owns the
translation between `WorkflowAddonExecutionInput` and gateway requests. This
keeps the gateway usable by other Swift applications and avoids a package
dependency cycle.

Riela exposes two version 1 built-ins:

- `riela/google-service-gateway-read`
- `riela/google-service-gateway-write`

The read add-on can call `services.list`, `services.get`, and `operations.get`.
The write add-on can call `services.enable`, `services.disable`, and
`services.batchEnable`. A workflow cannot select a mutation through the read
add-on.

## Add-on contract

`addon.config.operation` is required and selects an operation within the
add-on's capability tier. Request values may be supplied by `addon.inputs` and
are read from Riela's resolved variables. Static config values are accepted as
fallbacks.

Read request values:

| Operation | Required | Optional |
| --- | --- | --- |
| `services.list` | `project` | `state`, `pageSize`, `pageToken`, `allPages` |
| `services.get` | `project`, `service` | none |
| `operations.get` | `operationName` | none |

Write request values:

| Operation | Required | Optional |
| --- | --- | --- |
| `services.enable` | `project`, `service` | polling values |
| `services.disable` | `project`, `service` | `disableDependentServices`, `checkUsage`, polling values |
| `services.batchEnable` | `project`, `services` | polling values |

Polling values are `wait`, `pollIntervalSeconds`, and `timeoutSeconds`. A Riela
step deadline further bounds the mutation timeout.

Credentials are never accepted in config or inputs. The add-on requires an
explicit environment binding whose target is
`GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN`:

```json
{
  "env": {
    "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": {
      "fromEnv": "MY_GOOGLE_ACCESS_TOKEN",
      "required": true
    }
  }
}
```

No ambient environment variable is forwarded implicitly. The Riela adapter
returns the typed gateway result below `payload.data` and translates gateway
errors to Riela provider errors without including the access token.

## Example

```json
{
  "id": "enable-calendar-api",
  "addon": {
    "name": "riela/google-service-gateway-write",
    "version": "1",
    "config": {
      "operation": "services.enable"
    },
    "inputs": {
      "project": "{{event.input.project}}",
      "service": "calendar"
    },
    "env": {
      "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": {
        "fromEnv": "GOOGLE_SERVICE_USAGE_TOKEN",
        "required": true
      }
    }
  }
}
```
