import Foundation
import Testing

@testable import GoogleServiceGatewayAdmin
@testable import GoogleServiceGatewayCore
@testable import GoogleServiceGatewayReader

@Test func gatewayDigestMatchesPublishedSHA256AndHMACVectors() {
  #expect(
    GatewayDigest.sha256Hex(Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  #expect(
    GatewayDigest.hmacSHA256Hex(
      key: Data("key".utf8),
      message: Data("The quick brown fox jumps over the lazy dog".utf8))
      == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
}

@Test func readerDiscoversBillingAccountsAndProjectBilling() async {
  let transport = BillingRecordingTransport(responses: [
    billingResponse(
      """
      {"billingAccounts":[{"name":"billingAccounts/ABCDEF-123456-789012","displayName":"Primary","open":true}],"nextPageToken":"next-token"}
      """),
    billingResponse(
      """
      {"projectId":"gateway-test-123","billingAccountName":"billingAccounts/ABCDEF-123456-789012","billingEnabled":true}
      """)
  ])
  let reader = ReaderAdapter(transport: transport)
  let accounts = await reader.run(
    arguments: ["billing", "accounts", "list", "--page-size", "25"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token"])
  let project = await reader.run(
    arguments: ["billing", "projects", "get", "--project", "gateway-test-123"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token"])

  #expect(!accounts.isError)
  #expect(accounts.output.contains("billing.accounts.list"))
  #expect(accounts.output.contains("next-token"))
  #expect(!project.isError)
  #expect(project.output.contains("billing.projects.get"))
  let requests = await transport.requests()
  #expect(requests[0].method == "GET")
  #expect(requests[0].url.absoluteString.contains("/v1/billingAccounts?pageSize=25"))
  #expect(requests[1].url.path == "/v1/projects/gateway-test-123/billingInfo")

  let invalid = await reader.run(
    arguments: ["billing", "accounts", "list", "--page-size", "101"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token"])
  #expect(invalid.isError)
  #expect(await transport.requests().count == 2)
}

@Test func billingAdminPlanIsSignedBoundAndSingleUse() async throws {
  let current =
    "{\"projectId\":\"gateway-test-123\",\"billingAccountName\":\"billingAccounts/OLDOLD-123456-789012\",\"billingEnabled\":true}"
  let updated =
    "{\"projectId\":\"gateway-test-123\",\"billingAccountName\":\"billingAccounts/NEWNEW-123456-789012\",\"billingEnabled\":true}"
  let transport = BillingRecordingTransport(responses: [
    billingResponse(current), billingResponse(current),
    billingResponse(updated, headers: ["x-request-id": "request-123"]),
    billingResponse(current)
  ])
  let client = GoogleCloudBillingClient(
    transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let key = Data(repeating: 0x41, count: 32)
  let clock = BillingFixedWallClock(date: Date(timeIntervalSince1970: 1_700_000_000))
  let service = GoogleCloudBillingAdmin(
    billing: client, clock: clock, nonceProvider: BillingFixedNonce())
  let plan = try await service.plan(
    operation: .link, project: "gateway-test-123",
    billingAccount: "billingAccounts/NEWNEW-123456-789012",
    credentialSelector: "access-token-env:ADMIN_TOKEN", signingKey: key)

  #expect(plan.schemaVersion == 1)
  #expect(plan.planID == "plan-123")
  #expect(plan.digest.count == 64)
  #expect(plan.signature.count == 64)
  let decoded = try BillingAdminPlan.decode(try GatewayJSONCodec.encode(plan))
  #expect(decoded == plan)

  let replay = BillingReplayStore()
  let result = try await service.apply(
    plan, expectedOperation: .link,
    credentialSelector: "access-token-env:ADMIN_TOKEN", signingKey: key,
    replayStore: replay)
  #expect(result.providerRequestID == "request-123")
  #expect(result.beforeFingerprint != result.afterFingerprint)

  await #expect(throws: GatewayError.self) {
    _ = try await service.apply(
      plan, expectedOperation: .link,
      credentialSelector: "access-token-env:ADMIN_TOKEN", signingKey: key,
      replayStore: replay)
  }
  #expect(await transport.requests().count == 4)
}

@Test func billingAdminRejectsTamperingExpiryAndCredentialSubstitutionBeforeNetwork() async throws {
  let current =
    "{\"projectId\":\"gateway-test-123\",\"billingAccountName\":\"billingAccounts/OLDOLD-123456-789012\",\"billingEnabled\":true}"
  let transport = BillingRecordingTransport(responses: [billingResponse(current)])
  let client = GoogleCloudBillingClient(
    transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let key = Data(repeating: 0x42, count: 32)
  let creation = GoogleCloudBillingAdmin(
    billing: client,
    clock: BillingFixedWallClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
    nonceProvider: BillingFixedNonce())
  let plan = try await creation.plan(
    operation: .unlink, project: "gateway-test-123", billingAccount: nil,
    credentialSelector: "oauth-profile:admin", signingKey: key, lifetime: 60)
  let replay = BillingReplayStore()

  let encodedPlan = try GatewayJSONCodec.encode(plan)
  let planString = try #require(String(bytes: encodedPlan, encoding: .utf8))
  let tamperedData = Data(
    planString.replacingOccurrences(
      of: "gateway-test-123", with: "gateway-evil-123").utf8)
  let tampered = try BillingAdminPlan.decode(tamperedData)
  await #expect(throws: GatewayError.self) {
    _ = try await creation.apply(
      tampered, expectedOperation: .unlink, credentialSelector: "oauth-profile:admin",
      signingKey: key, replayStore: replay)
  }

  await #expect(throws: GatewayError.self) {
    _ = try await creation.apply(
      plan, expectedOperation: .unlink, credentialSelector: "oauth-profile:other",
      signingKey: key, replayStore: replay)
  }
  let expired = GoogleCloudBillingAdmin(
    billing: client,
    clock: BillingFixedWallClock(date: Date(timeIntervalSince1970: 1_700_000_061)))
  await #expect(throws: GatewayError.self) {
    _ = try await expired.apply(
      plan, expectedOperation: .unlink, credentialSelector: "oauth-profile:admin",
      signingKey: key, replayStore: replay)
  }
  #expect(await transport.requests().count == 1)
}

@Test func adminAdapterEmitsCredentialBoundPlanWithoutSecrets() async throws {
  let transport = BillingRecordingTransport(responses: [
    billingResponse(
      "{\"projectId\":\"gateway-test-123\",\"billingAccountName\":\"\",\"billingEnabled\":false}")
  ])
  let result = await AdminAdapter(
    transport: transport,
    clock: BillingFixedWallClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
    nonceProvider: BillingFixedNonce(), replayStore: BillingReplayStore()
  ).run(
    arguments: [
      "billing", "projects", "link", "plan", "--project", "gateway-test-123",
      "--billing-account", "billingAccounts/NEWNEW-123456-789012",
      "--access-token-env", "ADMIN_TOKEN"
    ],
    environment: [
      "ADMIN_TOKEN": "provider-token",
      "GOOGLE_SERVICE_GATEWAY_ADMIN_PLAN_KEY": String(repeating: "k", count: 32)
    ])

  #expect(!result.isError)
  #expect(result.output.contains("credentialSelector"))
  #expect(result.output.contains("access-token-env:ADMIN_TOKEN"))
  #expect(!result.output.contains("provider-token"))
}

@Test func fileAdminReplayStoreConsumesPlanAtomically() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("google-service-gateway-admin-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try FileAdminPlanReplayStore(path: directory.path)

  try await store.consume(planID: "plan-123", digest: String(repeating: "a", count: 64))
  await #expect(throws: GatewayError.self) {
    try await store.consume(planID: "plan-123", digest: String(repeating: "a", count: 64))
  }
  let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

private actor BillingRecordingTransport: GatewayHTTPTransport {
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

private actor BillingReplayStore: AdminPlanReplayStore {
  private var consumed: Set<String> = []

  func consume(planID: String, digest _: String) async throws {
    guard consumed.insert(planID).inserted else {
      throw GatewayError(.failedPrecondition, "admin plan has already been consumed")
    }
  }
}

private struct BillingFixedWallClock: GatewayWallClock {
  let date: Date
  func now() -> Date { date }
}

private struct BillingFixedNonce: GatewayNonceProvider {
  func nonce() -> String { "plan-123" }
}

private func billingResponse(
  _ json: String, status: Int = 200, headers: [String: String] = [:]
) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
}
