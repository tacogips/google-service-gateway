# OAuth and API-key Management

## Status

Approved for implementation

## Provider capability boundary

The gateway uses only documented Google endpoints. Google provides supported
interfaces for the OAuth authorization-code, token refresh, and revocation
flows, and for the complete API Keys API v2 lifecycle. Google does not provide
a supported public API for creating general Google Auth Platform clients or for
editing the general consent-screen configuration. The retired IAP OAuth Admin
API is not a substitute: its clients were IAP-only and its mutation surface has
been shut down.

Consequently, client and consent setup is an assisted workflow:

1. the gateway emits the project-specific Google Auth Platform Console URL and
   validates the intended redirect and scopes;
2. the operator creates the desktop client and configures the consent screen in
   Google's UI;
3. the downloaded client JSON is imported into the gateway's secure credential
   store;
4. the gateway performs PKCE login, token exchange, refresh, and revocation
   without `gcloud`.

The gateway must never call undocumented `clientauthconfig` Console endpoints
or claim that a local setup record changed Google-side consent configuration.

## Products and capability separation

- `google-service-gateway-reader` adds API-key metadata list/get operations. It
  never retrieves the key string.
- `google-service-gateway-writer` adds API-key create, restrict/update, delete,
  undelete, and the explicitly sensitive `get-key-string` operation.
- `google-service-gateway-auth` owns OAuth client import, assisted setup, scope
  profiles, interactive PKCE login, refresh, token retrieval, and revocation.
- `GoogleServiceGatewayCore` exposes all clients and storage protocols for
  in-process Riela nodes. Callers inject transports and credential stores.

## OAuth commands

```text
google-service-gateway-auth clients setup --project PROJECT [--type desktop]
google-service-gateway-auth clients import --profile NAME --file FILE
google-service-gateway-auth clients list
google-service-gateway-auth clients delete --profile NAME

google-service-gateway-auth consent setup --project PROJECT [--profile NAME] \
  [--scope ALIAS-OR-URI ...]
google-service-gateway-auth consent get --profile NAME
google-service-gateway-auth consent delete --profile NAME
google-service-gateway-auth scopes list [--service SERVICE]

google-service-gateway-auth oauth login --profile NAME \
  [--scope ALIAS-OR-URI ...] [--no-open] [--timeout SECONDS]
google-service-gateway-auth oauth refresh --profile NAME
google-service-gateway-auth oauth token --profile NAME
google-service-gateway-auth oauth revoke --profile NAME
```

Login uses a loopback redirect on `127.0.0.1`, a random CSRF state, and PKCE
S256. It requests offline access and explicit consent when a new refresh token
is required. Token responses are checked against the requested state and
granted scopes. Refresh tokens and imported client secrets are stored in macOS
Keychain. Access and refresh tokens are never written to ordinary files.

`oauth token` and `oauth refresh` intentionally return an access token because
they are credential-output commands. Other commands never return access or
refresh tokens. `oauth revoke` removes the stored token only after Google has
accepted revocation, unless an explicit local-only deletion is requested in a
future extension.

## Scope aliases

The scope catalog is a local, versioned convenience layer. Full HTTPS scope
URIs are always accepted. Initial aliases cover Calendar, Drive, Gmail, Sheets,
Docs, OpenID identity, and the Cloud Platform management scope. Consent setup
reports the resolved URIs and the Console URL; it does not imply Google-side
consent-screen mutation.

## API-key commands

```text
google-service-gateway-reader api-keys list --project PROJECT
google-service-gateway-reader api-keys get --key RESOURCE

google-service-gateway-writer api-keys create --project PROJECT \
  --display-name NAME [--key-id ID] [--api-target SERVICE ...] \
  [--allowed-ip CIDR ... | --allowed-referrer PATTERN ... |
   --allowed-bundle-id ID ...]
google-service-gateway-writer api-keys restrict --key RESOURCE \
  [--display-name NAME] [--api-target SERVICE ...] \
  [--allowed-ip CIDR ... | --allowed-referrer PATTERN ... |
   --allowed-bundle-id ID ...]
google-service-gateway-writer api-keys get-key-string --key RESOURCE
google-service-gateway-writer api-keys delete --key RESOURCE
google-service-gateway-writer api-keys undelete --key RESOURCE
```

All mutations poll API Keys API v2 long-running operations by default. API
targets use canonical `*.googleapis.com` names and the existing aliases. Client
restriction kinds are mutually exclusive, matching Google's resource model.
Creation requires at least one API target; unrestricted key creation is rejected
locally. `get-key-string` is the only API-key command allowed to emit the secret
key string.

## Riela contract

Riela nodes receive credential-store bindings as capabilities rather than
ordinary JSON input. Read nodes can list client profiles, scope metadata, and
API-key metadata. Write nodes can mutate API keys. Interactive browser login is
a host/UI operation; headless workflows use an already stored refresh token and
the core refreshing `AccessTokenProvider`. Secret-returning operations require
an explicit secret-output capability and must not be included in routine logs,
traces, or cached node output.

Reader and writer commands accept `--oauth-profile NAME` as an alternative to
`--access-token-env`. The profile provider refreshes near-expiry access tokens
and writes the rotated token back through `SecureCredentialStore`.
