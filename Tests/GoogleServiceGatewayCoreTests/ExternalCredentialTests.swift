import Foundation
import GoogleServiceGatewayCore
import GoogleServiceGatewayReader
import GoogleServiceGatewayAuth
import Testing

@Test func serviceExternalDirectTokenAndLegacyTokenSelectorAreAccepted() async throws {
  let direct = try #require(try GoogleServiceExternalCredentials.tokenProvider(environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "direct-token"]))
  #expect(try await direct.accessToken() == "direct-token")
  let alias = try #require(try GoogleServiceExternalCredentials.tokenProvider(environment: ["CUSTOM_TOKEN": "custom-token"], tokenEnvironment: "CUSTOM_TOKEN"))
  #expect(try await alias.accessToken() == "custom-token")
  #expect(throws: GatewayError.self) {
    _ = try GoogleServiceExternalCredentials.tokenProvider(environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "bad\ntoken"])
  }
}

@Test func explicitVaultProfileIgnoresGlobalCredentialsButAcceptsItsOwnInputs() async throws {
  let environment = ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "global-token"]
  #expect(try GoogleServiceExternalCredentials.tokenProvider(environment: environment, profile: "work") == nil)
  let selected = try #require(try GoogleServiceExternalCredentials.tokenProvider(environment: [
    "GOOGLE_SERVICE_GATEWAY_CREDENTIAL_WORK_ACCESS_TOKEN": "profile-token", "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "global-token"
  ], profile: "work"))
  #expect(try await selected.accessToken() == "profile-token")
}

@Test func serviceTokenJSONAcceptsVaultAndISODateFormatsWithoutClient() async throws {
  let token = OAuthTokenCredential(accessToken: "json-token", refreshToken: nil, tokenType: "Bearer",
                                   scopes: ["https://www.googleapis.com/auth/cloud-platform"], expiresAt: Date().addingTimeInterval(3600))
  for encoder in [JSONEncoder(), isoDateEncoder()] {
    let json = try #require(String(data: encoder.encode(token), encoding: .utf8))
    let provider = try #require(try GoogleServiceExternalCredentials.tokenProvider(environment: ["GOOGLE_SERVICE_GATEWAY_TOKEN_STORE_JSON": json]))
    #expect(try await provider.accessToken() == "json-token")
  }
  let expired = OAuthTokenCredential(accessToken: "expired-token", refreshToken: "refresh", tokenType: "Bearer", scopes: [], expiresAt: .distantPast)
  let json = try #require(String(data: JSONEncoder().encode(expired), encoding: .utf8))
  #expect(throws: GatewayError.self) {
    _ = try GoogleServiceExternalCredentials.tokenProvider(environment: ["GOOGLE_SERVICE_GATEWAY_TOKEN_STORE_JSON": json])
  }
}

@Test func serviceExternalCredentialConflictsDoNotExposeValues() throws {
  do {
    _ = try GoogleServiceExternalCredentials.tokenProvider(environment: [
      "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "canonical-secret", "CUSTOM_TOKEN": "alias-secret"
    ], tokenEnvironment: "CUSTOM_TOKEN")
    Issue.record("Expected conflicting token inputs to fail")
  } catch let error as GatewayError {
    #expect(!String(describing: error).contains("canonical-secret"))
    #expect(!String(describing: error).contains("alias-secret"))
  }
  #expect(throws: GatewayError.self) {
    _ = try GoogleServiceExternalCredentials.tokenProvider(environment: [
      "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token", "GOOGLE_SERVICE_GATEWAY_SERVICE_ACCOUNT_JSON": "{}"
    ])
  }
}

@Test func externalTokenFilesArePrivateBoundedAndNeverRefreshedOrWritten() async throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let path = root.appendingPathComponent("token.json")
  let token = OAuthTokenCredential(accessToken: "file-token", refreshToken: nil, tokenType: "Bearer", scopes: [], expiresAt: Date().addingTimeInterval(3600))
  let original = try JSONEncoder().encode(token)
  try original.write(to: path)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  let provider = try #require(try GoogleServiceExternalCredentials.tokenProvider(environment: ["GOOGLE_SERVICE_GATEWAY_TOKEN_STORE_PATH": path.path]))
  #expect(try await provider.accessToken() == "file-token")
  #expect(try Data(contentsOf: path) == original)
  let link = root.appendingPathComponent("link.json")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
  #expect(throws: GatewayError.self) {
    _ = try GoogleServiceExternalCredentials.tokenProvider(environment: ["GOOGLE_SERVICE_GATEWAY_TOKEN_STORE_PATH": link.path])
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
  #expect(throws: GatewayError.self) {
    _ = try GoogleServiceExternalCredentials.tokenProvider(environment: ["GOOGLE_SERVICE_GATEWAY_TOKEN_STORE_PATH": path.path])
  }
}

@Test func serviceReaderRequestUsesExternalTokenJSONWithoutVaultSetup() async throws {
  let token = OAuthTokenCredential(accessToken: "external-token", refreshToken: nil, tokenType: "Bearer", scopes: [], expiresAt: Date().addingTimeInterval(3600))
  let json = try #require(String(data: JSONEncoder().encode(token), encoding: .utf8))
  let result = await ReaderAdapter(transport: ExternalServiceTransport()).run(
    arguments: ["services", "list", "--project", "123"], environment: ["GOOGLE_SERVICE_GATEWAY_TOKEN_STORE_JSON": json])
  #expect(result.exitStatus == 0)
  #expect(!result.output.contains("external-token"))
}

private func isoDateEncoder() -> JSONEncoder {
  let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
  return encoder
}

private struct ExternalServiceTransport: GatewayHTTPTransport {
  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    #expect(request.headers["Authorization"] == "Bearer external-token")
    #expect(request.url.host != "oauth2.googleapis.com")
    return GatewayHTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"services":[]}"#.utf8))
  }
}

@Test func serviceLoginUsesCanonicalApplicationJSONAndDefaultProfileWithoutVaultSetup() async throws {
  let json = #"{"installed":{"client_id":"external-desktop-client","auth_uri":"https://accounts.google.com/o/oauth2/v2/auth","token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://127.0.0.1"]}}"#
  let client = try #require(try GoogleServiceExternalCredentials.oauthClient(environment: ["GOOGLE_SERVICE_GATEWAY_OAUTH_CLIENT_JSON": json], profile: "google-personal"))
  #expect(client.clientID == "external-desktop-client")
  let result = await AuthAdapter(vault: OAuthCredentialVault(store: EmptyExternalTestStore()), authorizer: ExternalApplicationAuthorizer()).run(
    arguments: ["auth", "login", "--scope", "https://www.googleapis.com/auth/cloud-platform"],
    environment: ["GOOGLE_SERVICE_GATEWAY_OAUTH_CLIENT_JSON": json])
  #expect(result.output.contains("test-authorizer-reached"))
  #expect(!result.output.contains("client profile not found"))
}

private struct EmptyExternalTestStore: SecureCredentialStore {
  func data(for account: String) async throws -> Data? { nil }
  func set(_ data: Data, for account: String) async throws { Issue.record("Cancelled login must not persist tokens") }
  func remove(account: String) async throws {}
  func accounts(prefix: String) async throws -> [String] { [] }
}

private struct ExternalApplicationAuthorizer: InteractiveOAuthAuthorizer {
  func authorize(client: OAuthClientConfiguration, scopes: [String], loginHint: String?, openBrowser: Bool,
                 timeout: TimeInterval) async throws -> (code: String, request: OAuthAuthorizationRequest) {
    #expect(client.clientID == "external-desktop-client")
    #expect(scopes == ["https://www.googleapis.com/auth/cloud-platform"])
    throw GatewayError(.cancelled, "test-authorizer-reached")
  }
}
