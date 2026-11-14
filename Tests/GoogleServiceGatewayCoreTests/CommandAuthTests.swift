import Foundation
import GoogleServiceGatewayCore
import GoogleServiceGatewayReader
import GoogleServiceGatewayWriter
import GoogleServiceGatewayAdmin
import GoogleServiceGatewayDeleter
import Testing

@Test(arguments: ["reader", "writer", "admin", "deleter"])
func serviceOperationalCommandsShareBrowserLogin(role: String) async throws {
  let vault = OAuthCredentialVault(store: CommandAuthStore())
  let authorizer = CommandAuthAuthorizer()
  let result = await runRoleAuth(role, vault: vault, authorizer: authorizer, transport: CommandAuthTransport(), environment: [
    "GOOGLE_SERVICE_GATEWAY_OAUTH_CLIENT_JSON": commandApplicationJSON
  ])
  #expect(!result.isError)
  #expect(result.exitStatus == 0)
  #expect(await authorizer.called())
  #expect(await authorizer.requestedScopes() == ["https://www.googleapis.com/auth/cloud-platform"])
  #expect(try await vault.token(profile: "google-personal")?.accessToken == "logged-in-token")
  #expect(try await vault.client(profile: "google-personal").clientID == "service-app")
  #expect(!result.output.contains("logged-in-token"))
}

@Test func serviceSavedDefaultLoginTokenWorksWithoutExternalInputs() async throws {
  let vault = OAuthCredentialVault(store: CommandAuthStore())
  let transport = CommandAuthTransport()
  let login = await runRoleAuth("reader", vault: vault, authorizer: CommandAuthAuthorizer(), transport: transport, environment: [
    "GOOGLE_SERVICE_GATEWAY_OAUTH_CLIENT_JSON": commandApplicationJSON
  ])
  #expect(!login.isError)
  let ordinary = await ReaderAdapter(transport: transport, vault: vault).run(arguments: ["services", "list", "--project", "123"], environment: [:])
  #expect(!ordinary.isError)
  #expect(ordinary.output.contains("services"))
  let explicitMissing = await ReaderAdapter(transport: transport, vault: vault).run(
    arguments: ["services", "list", "--project", "123", "--access-token-env", "MISSING_EXTERNAL_TOKEN"], environment: [:])
  #expect(explicitMissing.isError)
  #expect(explicitMissing.output.contains("access token is required"))
}

@Test(arguments: ["reader", "writer", "admin", "deleter"])
func serviceStatusChecksExternalCredentialsWithoutBrowserOrProviderCalls(role: String) async {
  let authorizer = CommandAuthAuthorizer()
  let result = await runRoleAuth(role, vault: OAuthCredentialVault(store: CommandAuthStore()), authorizer: authorizer,
    transport: CommandAuthTransport(), environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "external-status-token"],
    arguments: ["auth", "status"])
  #expect(result.exitStatus == 0)
  #expect(result.output.contains("READY"))
  #expect(result.output.contains("EXTERNAL"))
  #expect(!result.output.contains("external-status-token"))
  #expect(!(await authorizer.called()))
}

@Test func serviceStatusReportsMissingAndExpiredSavedCredentialsWithoutAClient() async throws {
  let vault = OAuthCredentialVault(store: CommandAuthStore())
  let adapter = AuthAdapter(vault: vault, oauth: GoogleOAuthClient(transport: CommandAuthTransport()), authorizer: CommandAuthAuthorizer())
  let missing = await adapter.run(arguments: ["auth", "status"], environment: [:])
  #expect(missing.exitStatus == 0)
  #expect(missing.output.contains("MISSING"))
  try await vault.saveToken(.init(accessToken: "expired-status-token", refreshToken: "status-refresh-token", tokenType: "Bearer",
                                 scopes: ["https://www.googleapis.com/auth/cloud-platform"], expiresAt: .distantPast), profile: "google-personal")
  let expired = await adapter.run(arguments: ["oauth", "status"], environment: [:])
  #expect(expired.exitStatus == 0)
  #expect(expired.output.contains("EXPIRED"))
  #expect(!expired.output.contains("expired-status-token"))
  #expect(!expired.output.contains("status-refresh-token"))
  let invalid = await adapter.run(arguments: ["auth", "status"], environment: ["GOOGLE_SERVICE_GATEWAY_TOKEN_STORE_JSON": "invalid-json"])
  #expect(invalid.isError)
  #expect(!invalid.output.contains("EXPIRED"))
}

@Test func serviceAuthRevokeAliasStillRequiresAnExplicitProfile() async {
  let result = await AuthAdapter(vault: OAuthCredentialVault(store: CommandAuthStore())).run(arguments: ["auth", "revoke"], environment: [:])
  #expect(result.isError)
  #expect(result.output.contains("--profile is required"))
  #expect(!result.output.contains("unknown auth command"))
}

@Test(arguments: ["reader", "writer", "admin", "deleter"])
func serviceOperationalLoginNeedsClientBeforeAuthorizing(role: String) async {
  let authorizer = CommandAuthAuthorizer()
  let result = await runRoleAuth(role, vault: OAuthCredentialVault(store: CommandAuthStore()), authorizer: authorizer,
                                 transport: CommandAuthTransport(), environment: [:])
  #expect(result.isError)
  #expect(!result.output.contains("unknown reader command"))
  #expect(!result.output.contains("unknown writer command"))
  #expect(!result.output.contains("plan signing key is required"))
  #expect(!(await authorizer.called()))
}

private let commandApplicationJSON = #"{"installed":{"client_id":"service-app","auth_uri":"https://accounts.google.com/o/oauth2/v2/auth","token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://127.0.0.1"]}}"#

private func runRoleAuth(
  _ role: String, vault: OAuthCredentialVault, authorizer: any InteractiveOAuthAuthorizer,
  transport: any GatewayHTTPTransport, environment: [String: String], arguments: [String] = ["auth", "login"]
) async -> RoleAuthOutcome {
  switch role {
  case "reader":
    let result = await ReaderAdapter(transport: transport, vault: vault, authAuthorizer: authorizer).run(arguments: arguments, environment: environment)
    return RoleAuthOutcome(output: result.output, isError: result.isError, exitStatus: result.exitStatus)
  case "writer":
    let result = await WriterAdapter(transport: transport, vault: vault, authAuthorizer: authorizer).run(arguments: arguments, environment: environment)
    return RoleAuthOutcome(output: result.output, isError: result.isError, exitStatus: result.exitStatus)
  case "admin":
    let result = await AdminAdapter(transport: transport, vault: vault, authAuthorizer: authorizer).run(arguments: arguments, environment: environment)
    return RoleAuthOutcome(output: result.output, isError: result.isError, exitStatus: result.exitStatus)
  default:
    let result = await DeleterAdapter(transport: transport, vault: vault, authAuthorizer: authorizer).run(arguments: arguments, environment: environment)
    return RoleAuthOutcome(output: result.output, isError: result.isError, exitStatus: result.exitStatus)
  }
}

private actor CommandAuthAuthorizer: InteractiveOAuthAuthorizer {
  private var didCall = false
  private var scopes: [String] = []
  func called() -> Bool { didCall }
  func requestedScopes() -> [String] { scopes }
  func authorize(client: OAuthClientConfiguration, scopes: [String], loginHint: String?, openBrowser: Bool,
                 timeout: TimeInterval) async throws -> (code: String, request: OAuthAuthorizationRequest) {
    didCall = true
    self.scopes = scopes
    #expect(openBrowser)
    let request = try GoogleOAuthClient().authorizationRequest(client: client,
      redirectURI: try #require(URL(string: "http://127.0.0.1:12345/oauth/callback")), scopes: scopes, loginHint: loginHint)
    return ("code", request)
  }
}

private struct CommandAuthTransport: GatewayHTTPTransport {
  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    if request.url.host == "oauth2.googleapis.com" {
      return GatewayHTTPResponse(statusCode: 200, body: Data(#"{"access_token":"logged-in-token","refresh_token":"refresh-token","expires_in":3600,"scope":"https://www.googleapis.com/auth/cloud-platform"}"#.utf8))
    }
    #expect(request.headers["Authorization"] == "Bearer logged-in-token")
    return GatewayHTTPResponse(statusCode: 200, body: Data(#"{"services":[]}"#.utf8))
  }
}

private actor CommandAuthStore: SecureCredentialStore {
  private var entries: [String: Data] = [:]
  func data(for account: String) -> Data? { entries[account] }
  func set(_ data: Data, for account: String) { entries[account] = data }
  func remove(account: String) { entries.removeValue(forKey: account) }
  func accounts(prefix: String) -> [String] { entries.keys.filter { $0.hasPrefix(prefix) } }
}

private struct RoleAuthOutcome {
  let output: String
  let isError: Bool
  let exitStatus: Int32
}

@Test(arguments: ["reader", "writer", "admin", "deleter"])
func serviceLogoutClearsLocalTokenWithoutNetworkAndPreservesClient(role: String) async throws {
  let vault = OAuthCredentialVault(store: CommandAuthStore())
  let authorizer = CommandAuthAuthorizer()
  let transport = CommandAuthTransport()
  let login = await runRoleAuth(role, vault: vault, authorizer: authorizer, transport: transport,
    environment: ["GOOGLE_SERVICE_GATEWAY_OAUTH_CLIENT_JSON": commandApplicationJSON])
  #expect(login.exitStatus == 0)
  let logout = await runRoleAuth(role, vault: vault, authorizer: authorizer, transport: transport,
    environment: [:], arguments: ["auth", "logout"])
  #expect(logout.exitStatus == 0)
  #expect(logout.output.contains("LOGGED_OUT"))
  #expect(try await vault.token(profile: "google-personal") == nil)
  #expect(try await vault.client(profile: "google-personal").clientID == "service-app")
  let repeated = await runRoleAuth(role, vault: vault, authorizer: authorizer, transport: transport,
    environment: [:], arguments: ["auth", "logout"])
  #expect(repeated.exitStatus == 0)
}

@Test func serviceLogoutPreservesExternallySelectedCredentialAndLocalToken() async throws {
  let vault = OAuthCredentialVault(store: CommandAuthStore())
  try await vault.saveToken(.init(accessToken: "local-fixture", refreshToken: nil, tokenType: "Bearer",
    scopes: [], expiresAt: .distantFuture), profile: "google-personal")
  let result = await AuthAdapter(vault: vault).run(arguments: ["auth", "logout"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "external-fixture"])
  #expect(result.exitStatus == 0)
  #expect(result.output.contains("EXTERNAL_CREDENTIAL_PRESERVED"))
  #expect(try await vault.token(profile: "google-personal")?.accessToken == "local-fixture")
  #expect(!result.output.contains("external-fixture"))
}
