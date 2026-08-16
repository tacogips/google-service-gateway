import Foundation
import Testing

@testable import GoogleServiceGatewayAuth
@testable import GoogleServiceGatewayCore
@testable import GoogleServiceGatewayReader
@testable import GoogleServiceGatewayWriter

#if canImport(CryptoKit)
  import CryptoKit
#endif

@Test func downloadedOAuthClientJSONIsValidatedAndImported() throws {
  let data = Data(
    """
    {"installed":{"client_id":"client.apps.googleusercontent.com","project_id":"sample-project","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","client_secret":"secret","redirect_uris":["http://localhost"]}}
    """.utf8)
  let client = try OAuthClientConfiguration.imported(from: data)
  #expect(client.kind == .installed)
  #expect(client.projectID == "sample-project")
  #expect(client.clientSecret == "secret")
  #expect(throws: GatewayError.self) {
    try OAuthClientConfiguration.imported(from: Data("{\"installed\":{}}".utf8))
  }
  let hostile = Data(
    """
    {"installed":{"client_id":"client","auth_uri":"https://attacker.example/auth","token_uri":"https://attacker.example/token","redirect_uris":["http://localhost"]}}
    """.utf8)
  #expect(throws: GatewayError.self) { try OAuthClientConfiguration.imported(from: hostile) }
}

@Test func importedOAuthClientCanBeBoundToExpectedProject() async throws {
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "google-service-gateway-client-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: temporary) }
  try Data(
    """
    {"installed":{"client_id":"client.apps.googleusercontent.com","project_id":"sample-project","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","client_secret":"secret","redirect_uris":["http://localhost"]}}
    """.utf8
  ).write(to: temporary)
  let adapter = AuthAdapter(
    vault: OAuthCredentialVault(store: MemoryCredentialStore()), authorizer: NeverAuthorizer())

  let accepted = await adapter.run(arguments: [
    "clients", "import", "--profile", "sample", "--file", temporary.path,
    "--project", "sample-project"
  ])
  #expect(!accepted.isError)

  let rejected = await adapter.run(arguments: [
    "clients", "import", "--profile", "wrong", "--file", temporary.path,
    "--project", "different-project"
  ])
  #expect(rejected.isError)
  #expect(rejected.output.contains("does not match"))
}

@Test func oauthAuthorizationUsesStatePKCEAndOfflineAccess() throws {
  let oauth = GoogleOAuthClient()
  let client = oauthTestClient()
  let request = try oauth.authorizationRequest(
    client: client,
    redirectURI: URL(string: "http://127.0.0.1:9191/oauth/callback")!,
    scopes: ["calendar.readonly", "drive.file"]
  )
  let query =
    URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
  #expect(query.contains(URLQueryItem(name: "response_type", value: "code")))
  #expect(query.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
  #expect(query.contains(URLQueryItem(name: "access_type", value: "offline")))
  #expect(query.contains(URLQueryItem(name: "state", value: request.state)))
  #expect(request.codeVerifier.count >= 43)
  #expect(
    request.requestedScopes == [
      "https://www.googleapis.com/auth/calendar.readonly",
      "https://www.googleapis.com/auth/drive.file",
    ])
  #if canImport(CryptoKit)
    let expectedChallenge = Data(SHA256.hash(data: Data(request.codeVerifier.utf8)))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    #expect(query.contains(URLQueryItem(name: "code_challenge", value: expectedChallenge)))
  #endif
}

@Test func loopbackAuthorizerReceivesAndValidatesCallback() async throws {
  let authorizer = LoopbackOAuthAuthorizer { authorizationURL, _ in
    let query =
      URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let redirect = try #require(query.first(where: { $0.name == "redirect_uri" })?.value)
    let state = try #require(query.first(where: { $0.name == "state" })?.value)
    var callback = try #require(URLComponents(string: redirect))
    callback.queryItems = [
      URLQueryItem(name: "code", value: "callback-code"), URLQueryItem(name: "state", value: state),
    ]
    let url = try #require(callback.url)
    Task { _ = try? await URLSession.shared.data(from: url) }
  }
  let result = try await authorizer.authorize(
    client: oauthTestClient(),
    scopes: ["calendar.readonly"],
    loginHint: nil,
    openBrowser: false,
    timeout: 5
  )
  #expect(result.code == "callback-code")
  #expect(result.request.redirectURI.host == "127.0.0.1")
}

@Test func loopbackAuthorizerRejectsDuplicateCallbackParameters() async throws {
  let authorizer = LoopbackOAuthAuthorizer { authorizationURL, _ in
    let query =
      URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let redirect = try #require(query.first(where: { $0.name == "redirect_uri" })?.value)
    let state = try #require(query.first(where: { $0.name == "state" })?.value)
    let callback = try #require(URL(string: "\(redirect)?code=one&code=two&state=\(state)"))
    Task { _ = try? await URLSession.shared.data(from: callback) }
  }
  await #expect(throws: GatewayError.self) {
    _ = try await authorizer.authorize(
      client: oauthTestClient(),
      scopes: ["openid"],
      loginHint: nil,
      openBrowser: false,
      timeout: 5
    )
  }
}

@Test func oauthExchangeRefreshAndRevokeUseDocumentedEndpoints() async throws {
  let transport = NewRecordingTransport(responses: [
    newResponse(
      "{\"access_token\":\"access-one\",\"refresh_token\":\"refresh-one\",\"expires_in\":3600,\"scope\":\"openid email\",\"token_type\":\"Bearer\"}"
    ),
    newResponse(
      "{\"access_token\":\"access-two\",\"expires_in\":1800,\"scope\":\"openid email\",\"token_type\":\"Bearer\"}"
    ),
    newResponse("{}"),
  ])
  let now = Date(timeIntervalSince1970: 1_000)
  let oauth = GoogleOAuthClient(transport: transport, now: { now })
  let client = oauthTestClient()
  let authorization = try oauth.authorizationRequest(
    client: client,
    redirectURI: URL(string: "http://127.0.0.1:9191/oauth/callback")!,
    scopes: ["openid", "email"]
  )
  let first = try await oauth.exchange(
    code: "authorization-code", request: authorization, client: client)
  #expect(first.refreshToken == "refresh-one")
  #expect(first.expiresAt == now.addingTimeInterval(3_600))
  let second = try await oauth.refresh(credential: first, client: client)
  #expect(second.accessToken == "access-two")
  #expect(second.refreshToken == "refresh-one")
  try await oauth.revoke(second)
  let requests = await transport.requests()
  #expect(requests.count == 3)
  #expect(requests[0].url.absoluteString == "https://oauth2.googleapis.com/token")
  #expect(
    String(decoding: requests[0].body ?? Data(), as: UTF8.self).contains(
      "grant_type=authorization_code"))
  #expect(
    String(decoding: requests[1].body ?? Data(), as: UTF8.self).contains("grant_type=refresh_token")
  )
  #expect(requests[2].url.absoluteString == "https://oauth2.googleapis.com/revoke")
}

@Test func credentialVaultStoresProfilesAndTokensBehindCapability() async throws {
  let store = MemoryCredentialStore()
  let vault = OAuthCredentialVault(store: store)
  let client = oauthTestClient()
  let token = OAuthTokenCredential(
    accessToken: "access",
    refreshToken: "refresh",
    tokenType: "Bearer",
    scopes: ["openid"],
    expiresAt: Date(timeIntervalSince1970: 2_000)
  )
  try await vault.saveClient(client, profile: "primary")
  try await vault.saveToken(token, profile: "primary")
  #expect(try await vault.client(profile: "primary") == client)
  #expect(try await vault.token(profile: "primary") == token)
  let profiles = try await vault.profiles()
  #expect(profiles.count == 1)
  #expect(profiles[0].hasToken)
  try await vault.removeProfile("primary")
  #expect(try await vault.profiles().isEmpty)
}

@Test func apiKeysClientListsMetadataAndExplicitlyRetrievesSecret() async throws {
  let resource = "projects/123/locations/global/keys/key-1"
  let transport = NewRecordingTransport(responses: [
    newResponse(
      "{\"keys\":[{\"name\":\"\(resource)\",\"displayName\":\"calendar-key\",\"restrictions\":{\"apiTargets\":[{\"service\":\"calendar-json.googleapis.com\"}]}}]}"
    ),
    newResponse("{\"name\":\"\(resource)\",\"displayName\":\"calendar-key\"}"),
    newResponse("{\"keyString\":\"provider-secret-key\"}"),
  ])
  let client = GoogleAPIKeysClient(
    transport: transport, tokenProvider: StaticAccessTokenProvider(token: "management-token"))
  let list = try await client.list(project: "123")
  #expect(
    list.keys.first?.restrictions?.apiTargets.first?.service == "calendar-json.googleapis.com")
  #expect(try await client.get(resource).key.displayName == "calendar-key")
  #expect(try await client.getKeyString(resource).keyString == "provider-secret-key")
  let requests = await transport.requests()
  #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer management-token" })
  #expect(requests[2].url.path.hasSuffix("/keyString"))
}

@Test func apiKeyCreateAndRestrictionUpdateAreValidatedBeforeTransport() async throws {
  let resource = "projects/123/locations/global/keys/key-1"
  let transport = NewRecordingTransport(responses: [
    newResponse("{\"name\":\"operations/create\",\"done\":false}"),
    newResponse("{\"name\":\"operations/restrict\",\"done\":false}"),
  ])
  let client = GoogleAPIKeysClient(
    transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let restrictions = APIKeyRestrictions(
    apiTargets: [APIKeyTarget(service: "calendar")],
    client: .server(allowedIPs: ["192.0.2.1"])
  )
  _ = try await client.create(
    .init(
      project: "123", displayName: "calendar-key", keyID: "calendar-key",
      restrictions: restrictions, options: .init(wait: false)))
  _ = try await client.restrict(resource, restrictions: restrictions, options: .init(wait: false))
  let requests = await transport.requests()
  #expect(requests[0].method == "POST")
  #expect(requests[0].url.query?.contains("keyId=calendar-key") == true)
  let createBody = String(decoding: requests[0].body ?? Data(), as: UTF8.self)
  #expect(createBody.contains("calendar-json.googleapis.com"))
  #expect(createBody.contains("192.0.2.1"))
  #expect(requests[1].method == "PATCH")

  let rejected = NewRecordingTransport(responses: [])
  let rejectedClient = GoogleAPIKeysClient(
    transport: rejected, tokenProvider: StaticAccessTokenProvider(token: "token"))
  await #expect(throws: GatewayError.self) {
    _ = try await rejectedClient.create(
      .init(
        project: "123",
        displayName: "unsafe",
        restrictions: .init(apiTargets: []),
        options: .init(wait: false)
      ))
  }
  #expect(await rejected.requests().isEmpty)
}

@Test func apiKeyOperationErrorsScrubEveryManagementToken() async throws {
  let transport = NewRecordingTransport(responses: [
    newResponse(
      """
      {"name":"operations/failure-management-token","done":true,"error":{"code":7,"message":"failed management-token","details":[{"message":"management-token","keyString":"provider-secret-key"}]}}
      """)
  ])
  let client = GoogleAPIKeysClient(
    transport: transport, tokenProvider: StaticAccessTokenProvider(token: "management-token"))
  do {
    _ = try await client.create(
      .init(
        project: "123",
        displayName: "calendar-key",
        restrictions: .init(apiTargets: [.init(service: "calendar")])
      ))
    Issue.record("expected operation failure")
  } catch let error as GatewayError {
    let output = String(decoding: try GatewayJSONCodec.encode(error), as: UTF8.self)
    #expect(!output.contains("management-token"))
    #expect(!output.contains("provider-secret-key"))
  }
}

@Test func readerAndWriterExposeAPIKeyCapabilityBoundary() async {
  let resource = "projects/123/locations/global/keys/key-1"
  let readerTransport = NewRecordingTransport(responses: [newResponse("{\"keys\":[]}")])
  let reader = await ReaderAdapter(transport: readerTransport).run(
    arguments: ["api-keys", "list", "--project", "123"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token"]
  )
  #expect(!reader.isError)
  #expect(reader.output.contains("api-keys.list"))

  let writerTransport = NewRecordingTransport(responses: [
    newResponse("{\"keyString\":\"provider-secret-key\"}")
  ])
  let writer = await WriterAdapter(transport: writerTransport).run(
    arguments: ["api-keys", "get-key-string", "--key", resource],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token"]
  )
  #expect(!writer.isError)
  #expect(writer.output.contains("provider-secret-key"))
}

@Test func readerCanAuthenticateFromStoredOAuthProfileWithoutEnvironmentToken() async throws {
  let store = MemoryCredentialStore()
  let vault = OAuthCredentialVault(store: store)
  try await vault.saveClient(oauthTestClient(), profile: "management")
  try await vault.saveToken(
    .init(
      accessToken: "stored-access-token",
      refreshToken: "stored-refresh-token",
      tokenType: "Bearer",
      scopes: ["https://www.googleapis.com/auth/cloud-platform"],
      expiresAt: Date().addingTimeInterval(3_600)
    ), profile: "management")
  let transport = NewRecordingTransport(responses: [newResponse("{\"services\":[]}")])
  let result = await ReaderAdapter(transport: transport, vault: vault).run(
    arguments: ["services", "list", "--project", "123", "--oauth-profile", "management"],
    environment: [:]
  )
  #expect(!result.isError)
  #expect(
    await transport.requests().first?.headers["Authorization"] == "Bearer stored-access-token")

  let conflict = await ReaderAdapter(transport: NewRecordingTransport(responses: []), vault: vault)
    .run(
      arguments: [
        "services", "list", "--project", "123", "--oauth-profile", "management",
        "--access-token-env", "TOKEN",
      ],
      environment: [:]
    )
  #expect(conflict.isError)
  #expect(conflict.exitStatus == 2)
}

@Test func authAdapterProvidesConsoleHandoffAndScopeResolution() async {
  let adapter = AuthAdapter(
    vault: OAuthCredentialVault(store: MemoryCredentialStore()), authorizer: NeverAuthorizer())
  let client = await adapter.run(arguments: ["clients", "setup", "--project", "sample-project"])
  #expect(!client.isError)
  #expect(client.output.contains("console.cloud.google.com"))
  #expect(client.output.contains("auth\\/clients"))
  #expect(client.output.contains("\"automated\":false"))
  let consent = await adapter.run(arguments: [
    "consent", "setup", "--project", "sample-project", "--scope", "calendar.readonly",
  ])
  #expect(!consent.isError)
  #expect(consent.output.contains("calendar.readonly"))
  let scopes = await adapter.run(arguments: ["scopes", "list", "--service", "gmail"])
  #expect(!scopes.isError)
  #expect(scopes.output.contains("gmail.send"))
}

@Test func consentScopeConfigurationDrivesProfileLogin() async throws {
  let store = MemoryCredentialStore()
  let vault = OAuthCredentialVault(store: store)
  try await vault.saveClient(oauthTestClient(), profile: "personal")
  let authorizer = ScopeCapturingAuthorizer()
  let transport = NewRecordingTransport(responses: [
    newResponse(
      "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/calendar.readonly\"}"
    )
  ])
  let adapter = AuthAdapter(
    vault: vault, oauth: GoogleOAuthClient(transport: transport), authorizer: authorizer)
  let setup = await adapter.run(arguments: [
    "consent", "setup", "--project", "sample-project", "--profile", "personal", "--scope",
    "calendar.readonly",
  ])
  #expect(!setup.isError)
  let get = await adapter.run(arguments: ["consent", "get", "--profile", "personal"])
  #expect(!get.isError)
  #expect(get.output.contains("calendar.readonly"))
  let login = await adapter.run(arguments: ["oauth", "login", "--profile", "personal"])
  #expect(!login.isError)
  #expect(
    await authorizer.capturedScopes() == [
      "https://www.googleapis.com/auth/calendar.readonly"
    ])
  let deleted = await adapter.run(arguments: ["consent", "delete", "--profile", "personal"])
  #expect(!deleted.isError)
  #expect(try await vault.scopeConfiguration(profile: "personal") == nil)
}

@Test func oauthLoginRejectsClientFromDifferentConfiguredProject() async throws {
  let store = MemoryCredentialStore()
  let vault = OAuthCredentialVault(store: store)
  try await vault.saveClient(oauthTestClient(), profile: "mismatched")
  try await vault.saveScopeConfiguration(
    .init(project: "different-project", scopes: ["openid"]),
    profile: "mismatched"
  )
  let adapter = AuthAdapter(vault: vault, authorizer: NeverAuthorizer())

  let result = await adapter.run(arguments: ["oauth", "login", "--profile", "mismatched"])
  #expect(result.isError)
  #expect(result.output.contains("does not match"))
}

@Test func sensitiveKeyFieldsAreRedactedOnlyOnDiagnosticPaths() throws {
  let value: JSONValue = .object([
    "keyString": .string("provider-secret-key"), "displayName": .string("safe"),
  ])
  let redacted = String(
    decoding: try GatewayJSONCodec.encode(Redactor.redact(value)), as: UTF8.self)
  #expect(!redacted.contains("provider-secret-key"))
  #expect(redacted.contains("safe"))
  let explicit = String(
    decoding: try GatewayJSONCodec.encode(
      APIKeyStringResult(name: "key", keyString: "provider-secret-key")), as: UTF8.self)
  #expect(explicit.contains("provider-secret-key"))
}

private actor NewRecordingTransport: GatewayHTTPTransport {
  private var recorded: [GatewayHTTPRequest] = []
  private var responses: [GatewayHTTPResponse]

  init(responses: [GatewayHTTPResponse]) { self.responses = responses }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !responses.isEmpty else { throw GatewayError(.unexpectedError, "no scripted response") }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private actor MemoryCredentialStore: SecureCredentialStore {
  private var values: [String: Data] = [:]

  func data(for account: String) async throws -> Data? { values[account] }
  func set(_ data: Data, for account: String) async throws { values[account] = data }
  func remove(account: String) async throws { values.removeValue(forKey: account) }
  func accounts(prefix: String) async throws -> [String] {
    values.keys.filter { $0.hasPrefix(prefix) }.sorted()
  }
}

private struct NeverAuthorizer: InteractiveOAuthAuthorizer {
  func authorize(
    client: OAuthClientConfiguration,
    scopes: [String],
    loginHint: String?,
    openBrowser: Bool,
    timeout: TimeInterval
  ) async throws -> (code: String, request: OAuthAuthorizationRequest) {
    throw GatewayError(.unexpectedError, "not used")
  }
}

private actor ScopeCapturingAuthorizer: InteractiveOAuthAuthorizer {
  private var scopes: [String] = []

  func authorize(
    client: OAuthClientConfiguration,
    scopes: [String],
    loginHint: String?,
    openBrowser: Bool,
    timeout: TimeInterval
  ) async throws -> (code: String, request: OAuthAuthorizationRequest) {
    self.scopes = scopes
    return (
      "code",
      OAuthAuthorizationRequest(
        authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        redirectURI: URL(string: "http://127.0.0.1:9000/oauth/callback")!,
        state: "state",
        codeVerifier: "verifier",
        requestedScopes: scopes
      )
    )
  }

  func capturedScopes() -> [String] { scopes }
}

private func oauthTestClient() -> OAuthClientConfiguration {
  OAuthClientConfiguration(
    kind: .installed,
    clientID: "client.apps.googleusercontent.com",
    clientSecret: "client-secret",
    projectID: "sample-project",
    redirectURIs: [URL(string: "http://localhost")!]
  )
}

private func newResponse(_ json: String, status: Int = 200) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: Data(json.utf8))
}
