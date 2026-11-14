import Foundation
import GoogleServiceGatewayCore
import GoogleServiceGatewayReader
import Testing

@Test func serviceAccountProviderExchangesSignedAssertionAndCachesToken() async throws {
  let transport = IAMRecordingTransport(responses: [
    iamResponse("""
      {"access_token":"short-lived-token","expires_in":3600,"token_type":"Bearer"}
      """)
  ])
  let provider = try ServiceAccountAccessTokenProvider(
    credentialJSON: serviceAccountFixture,
    transport: transport,
    signer: FixedJWTSigner(),
    clock: FixedWallClock())

  #expect(try await provider.accessToken() == "short-lived-token")
  #expect(try await provider.accessToken() == "short-lived-token")
  let requests = await transport.requests()
  #expect(requests.count == 1)
  #expect(requests[0].method == "POST")
  #expect(requests[0].url.absoluteString == "https://oauth2.googleapis.com/token")
  #expect(requests[0].headers["Content-Type"] == "application/x-www-form-urlencoded")
  let body = try #require(String(bytes: requests[0].body ?? Data(), encoding: .utf8))
  #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"))
  #expect(body.contains("assertion="))
  #expect(!body.contains("PRIVATE"))
}

@Test func projectIAMPermissionTestPreservesCaseAndReportsMissingPermissions() async throws {
  let transport = IAMRecordingTransport(responses: [
    iamResponse("{\"permissions\":[\"resourcemanager.projects.getIamPolicy\"]}")
  ])
  let client = GoogleProjectIAMClient(
    transport: transport, tokenProvider: StaticAccessTokenProvider(token: "management-token"))
  let result = try await client.testPermissions(
    project: "gateway-test-123",
    permissions: ["resourcemanager.projects.setIamPolicy", "resourcemanager.projects.getIamPolicy"])

  #expect(result.grantedPermissions == ["resourcemanager.projects.getIamPolicy"])
  let request = try #require(await transport.requests().first)
  #expect(
    request.url.absoluteString
      == "https://cloudresourcemanager.googleapis.com/v3/projects/gateway-test-123/:testIamPermissions")
  #expect(request.headers["Authorization"] == "Bearer management-token")
  #expect(
    try GatewayJSONCodec.decode(request.body ?? Data())
      == .object([
        "permissions": .array([
          .string("resourcemanager.projects.getIamPolicy"),
          .string("resourcemanager.projects.setIamPolicy")
        ])
      ]))
}

@Test func readerUsesServiceAccountCredentialWithoutGcloudOrOAuthProfile() async throws {
  let transport = IAMRecordingTransport(responses: [
    iamResponse("""
      {"access_token":"native-token","expires_in":3600,"token_type":"Bearer"}
      """),
    iamResponse("{\"permissions\":[]}")
  ])
  let result = await ReaderAdapter(transport: transport, serviceAccountSigner: FixedJWTSigner()).run(
    arguments: [
      "iam", "permissions", "test", "--project", "gateway-test-123",
      "--permission", "serviceusage.services.enable",
      "--service-account-env", "TEST_SERVICE_ACCOUNT"
    ],
    environment: ["TEST_SERVICE_ACCOUNT": serviceAccountFixture])

  #expect(!result.isError)
  #expect(result.output.contains("\"command\":\"iam.permissions.test\""))
  #expect(result.output.contains("serviceusage.services.enable"))
  #expect(await transport.requests().count == 2)
}

private struct FixedJWTSigner: ServiceAccountJWTSigner {
  func signSHA256RSA(message: Data, privateKeyPEM: String) throws -> Data {
    #expect(!message.isEmpty)
    #expect(privateKeyPEM.hasPrefix(privateKeyBegin))
    return Data("signature".utf8)
  }
}

private struct FixedWallClock: GatewayWallClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private actor IAMRecordingTransport: GatewayHTTPTransport {
  private var recorded: [GatewayHTTPRequest] = []
  private var responses: [GatewayHTTPResponse]

  init(responses: [GatewayHTTPResponse]) { self.responses = responses }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !responses.isEmpty else { throw GatewayError(.unexpectedError, "no response") }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private let privateKeyBegin = "-----BEGIN " + "PRIVATE KEY-----"
private let privateKeyEnd = "-----END " + "PRIVATE KEY-----"
private let serviceAccountFixture = """
  {
    "type":"service_account",
    "client_email":"gateway@example.iam.gserviceaccount.com",
    "private_key":"\(privateKeyBegin)\\nfixture\\n\(privateKeyEnd)\\n",
    "token_uri":"https://oauth2.googleapis.com/token"
  }
  """

private func iamResponse(_ json: String, status: Int = 200) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: Data(json.utf8))
}
