import Foundation
import Testing

@testable import GoogleServiceGatewayCore
@testable import GoogleServiceGatewayWriter

@Test func projectProvisioningCreatesAndEnablesServicesWithoutBillingAuthority() async throws {
  let transport = ProjectRecordingTransport(responses: [
    projectResponse("{\"name\":\"operations/pc.123\"}"),
    projectResponse(
      """
      {
        "name":"operations/pc.123",
        "done":true,
        "response":{
          "name":"projects/123456789",
          "projectId":"gateway-test-123",
          "displayName":"Gateway Test",
          "parent":"organizations/987654321",
          "state":"ACTIVE",
          "labels":{"environment":"test"},
          "createTime":"2026-08-16T00:00:00Z"
        }
      }
      """),
    projectResponse(
      "{\"name\":\"operations/service.123\",\"done\":true,\"response\":{}}")
  ])
  let client = GoogleProjectProvisioningClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: "management-token"),
    sleeper: ProjectNoopSleeper(),
    clock: ProjectFixedClock()
  )

  let result = try await client.create(
    .init(
      projectID: "gateway-test-123",
      displayName: "Gateway Test",
      parent: "organizations/987654321",
      labels: ["environment": "test"],
      services: ["calendar", "gmail"],
      oauthScopes: ["calendar.readonly", "gmail.send"]
    ))

  #expect(result.project?.projectID == "gateway-test-123")
  #expect(result.project?.resourceName == "projects/123456789")
  #expect(result.billing == nil)
  #expect(result.serviceEnablement?.requestedServices == [
    "calendar-json.googleapis.com", "gmail.googleapis.com"
  ])
  #expect(result.oauthClientSetup.automated == false)
  #expect(result.oauthConsentSetup.scopes == [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/gmail.send"
  ])

  let requests = await transport.requests()
  #expect(requests.count == 3)
  #expect(requests[0].method == "POST")
  #expect(requests[0].url.absoluteString == "https://cloudresourcemanager.googleapis.com/v3/projects")
  #expect(requests[1].url.path == "/v3/operations/pc.123")
  #expect(requests[2].url.path == "/v1/projects/gateway-test-123/services:batchEnable")
  #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer management-token" })

  let createBody = try GatewayJSONCodec.decode(try #require(requests[0].body))
  #expect(
    createBody == .object([
      "projectId": .string("gateway-test-123"),
      "displayName": .string("Gateway Test"),
      "parent": .string("organizations/987654321"),
      "labels": .object(["environment": .string("test")])
    ]))
}

@Test func writerRejectsBillingAttachmentBeforeNetworkAccess() async {
  let transport = ProjectRecordingTransport(responses: [])
  let result = await WriterAdapter(transport: transport).run(
    arguments: [
      "projects", "create", "--project-id", "gateway-test-123",
      "--display-name", "Gateway Test",
      "--billing-account", "billingAccounts/ABCDEF-123456-789012",
    ],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "management-token"])

  #expect(result.isError)
  #expect(result.output.contains("options are not valid for this command"))
  #expect(await transport.requests().isEmpty)
}

@Test func writerExposesProjectProvisioningCommandAndOAuthHandoff() async {
  let transport = ProjectRecordingTransport(responses: [
    projectResponse(
      """
      {"name":"operations/pc.done","done":true,"response":{"name":"projects/123456789","projectId":"gateway-test-456","displayName":"Gateway Test","state":"ACTIVE"}}
      """)
  ])
  let result = await WriterAdapter(transport: transport).run(
    arguments: [
      "projects", "create",
      "--project-id", "gateway-test-456",
      "--display-name", "Gateway Test",
      "--scope", "calendar.readonly"
    ],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "management-token"]
  )

  #expect(!result.isError)
  #expect(result.output.contains("\"command\":\"projects.create\""))
  #expect(result.output.contains("oauthClientSetup"))
  #expect(result.output.contains("oauthConsentSetup"))
  #expect(result.output.contains("calendar.readonly"))
}

@Test func projectProvisioningRejectsPostCreationWorkWithoutWaiting() async {
  let transport = ProjectRecordingTransport(responses: [])
  let result = await WriterAdapter(transport: transport).run(
    arguments: [
      "projects", "create",
      "--project-id", "gateway-test-789",
      "--display-name", "Gateway Test",
      "--service", "calendar",
      "--no-wait"
    ],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "management-token"]
  )

  #expect(result.isError)
  #expect(result.exitStatus == 2)
  #expect(result.output.contains("--no-wait cannot be combined"))
  #expect(await transport.requests().isEmpty)
}

@Test func projectProvisioningValidatesProviderIdentityAndLocalInputs() async {
  #expect(throws: GatewayError.self) { try GatewayValidation.projectID("123456") }
  #expect(throws: GatewayError.self) { try GatewayValidation.projectDisplayName("bad_name") }
  #expect(throws: GatewayError.self) { try GatewayValidation.projectParent("projects/123") }
  #expect(throws: GatewayError.self) {
    try GatewayValidation.projectLabels(["Invalid": "value"])
  }

  let transport = ProjectRecordingTransport(responses: [
    projectResponse(
      """
      {"name":"operations/pc.done","done":true,"response":{"name":"projects/123456789","projectId":"different-project","displayName":"Gateway Test","state":"ACTIVE"}}
      """)
  ])
  let client = GoogleProjectProvisioningClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: "management-token")
  )
  await #expect(throws: GatewayError.self) {
    _ = try await client.create(
      .init(projectID: "gateway-test-123", displayName: "Gateway Test"))
  }
}

@Test func projectProvisioningRejectsSubstitutedOperationName() async {
  let transport = ProjectRecordingTransport(responses: [
    projectResponse("{\"name\":\"operations/pc.expected\"}"),
    projectResponse(
      """
      {"name":"operations/pc.substituted","done":true,"response":{"name":"projects/123456789","projectId":"gateway-test-123","displayName":"Gateway Test","state":"ACTIVE"}}
      """)
  ])
  let client = GoogleProjectProvisioningClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: "management-token"),
    sleeper: ProjectNoopSleeper(),
    clock: ProjectFixedClock()
  )

  await #expect(throws: GatewayError.self) {
    _ = try await client.create(
      .init(projectID: "gateway-test-123", displayName: "Gateway Test"))
  }
  #expect(await transport.requests().count == 2)
}

private actor ProjectRecordingTransport: GatewayHTTPTransport {
  private var recorded: [GatewayHTTPRequest] = []
  private var responses: [GatewayHTTPResponse]

  init(responses: [GatewayHTTPResponse]) { self.responses = responses }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !responses.isEmpty else {
      throw GatewayError(.unexpectedError, "no scripted response")
    }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private struct ProjectNoopSleeper: GatewaySleeper {
  func sleep(for _: TimeInterval) async throws {}
}

private struct ProjectFixedClock: GatewayClock {
  func now() -> TimeInterval { 0 }
}

private func projectResponse(_ json: String, status: Int = 200) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: Data(json.utf8))
}
