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
  transport: any GatewayHTTPTransport, environment: [String: String]
) async -> RoleAuthOutcome {
  let arguments = ["auth", "login"]
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
