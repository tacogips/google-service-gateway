import Foundation
import Testing

@testable import GoogleServiceGatewayCore
@testable import GoogleServiceGatewayDeleter
@testable import GoogleServiceGatewayWriter

@Test func projectDeleteAndUndeleteUseResourceManagerLifecycleEndpoints() async throws {
  let transport = DeleterRecordingTransport(responses: [
    deleterResponse(
      "{\"name\":\"operations/project-delete\",\"done\":true,\"response\":{}}"),
    deleterResponse(
      "{\"name\":\"operations/project-undelete\",\"done\":true,\"response\":{}}")
  ])
  let client = GoogleProjectProvisioningClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: "management-token")
  )

  let deleted = try await client.delete(project: "gateway-test-123")
  let restored = try await client.undelete(project: "gateway-test-123")

  #expect(deleted.action == .delete)
  #expect(restored.action == .undelete)
  let requests = await transport.requests()
  #expect(requests.count == 2)
  #expect(requests[0].method == "DELETE")
  #expect(requests[0].url.path == "/v3/projects/gateway-test-123")
  #expect(requests[0].body == nil)
  #expect(requests[1].method == "POST")
  #expect(requests[1].url.path == "/v3/projects/gateway-test-123:undelete")
  #expect(requests[1].body == Data("{}".utf8))
}

@Test func deleterOwnsAPIKeyDeleteAndUndeleteCommands() async {
  let resource = "projects/123/locations/global/keys/key-1"
  let transport = DeleterRecordingTransport(responses: [
    deleterResponse("{\"name\":\"operations/key-delete\",\"done\":true,\"response\":{}}"),
    deleterResponse("{\"name\":\"operations/key-undelete\",\"done\":true,\"response\":{}}")
  ])
  let adapter = DeleterAdapter(transport: transport)

  let deleted = await adapter.run(
    arguments: ["api-keys", "delete", "--key", resource],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "management-token"]
  )
  let restored = await adapter.run(
    arguments: ["api-keys", "undelete", "--key", resource],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "management-token"]
  )

  #expect(!deleted.isError)
  #expect(deleted.output.contains("\"command\":\"api-keys.delete\""))
  #expect(!restored.isError)
  #expect(restored.output.contains("\"command\":\"api-keys.undelete\""))
}

@Test func writerRejectsDeleteCommandsBeforeAuthenticationOrTransport() async {
  let transport = DeleterRecordingTransport(responses: [])
  let writer = WriterAdapter(transport: transport)

  let apiKey = await writer.run(
    arguments: [
      "api-keys", "delete", "--key", "projects/123/locations/global/keys/key-1"
    ],
    environment: [:]
  )
  let project = await writer.run(
    arguments: ["projects", "delete", "--project", "gateway-test-123"],
    environment: [:]
  )

  #expect(apiKey.isError && apiKey.exitStatus == 2)
  #expect(apiKey.output.contains("writer does not support delete commands"))
  #expect(project.isError && project.exitStatus == 2)
  #expect(await transport.requests().isEmpty)
}

@Test func deleterHelpAndAuthenticationContractsAreStable() async {
  let adapter = DeleterAdapter(transport: DeleterRecordingTransport(responses: []))
  let help = await adapter.run(arguments: ["--help"], environment: [:])
  #expect(!help.isError)
  #expect(help.output.contains("projects delete"))
  #expect(help.output.contains("api-keys undelete"))
  #expect(!help.output.contains("services enable"))

  let missingToken = await adapter.run(
    arguments: ["projects", "delete", "--project", "gateway-test-123"],
    environment: [:]
  )
  #expect(missingToken.exitStatus == 3)
  #expect(missingToken.output.contains("AUTH_REQUIRED"))
}

@Test func deleterRejectsAlreadyCompletedProviderFailureEvenWithoutWaiting() async {
  let transport = DeleterRecordingTransport(responses: [
    deleterResponse(
      """
      {"name":"operations/failed-delete","done":true,"error":{"code":7,"message":"permission denied"}}
      """)
  ])
  let client = GoogleProjectProvisioningClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: "management-token")
  )

  do {
    _ = try await client.delete(
      project: "gateway-test-123",
      options: .init(wait: false)
    )
    Issue.record("expected completed operation failure")
  } catch let error as GatewayError {
    #expect(error.code == .operationFailed)
    #expect(error.operationName == "operations/failed-delete")
  } catch {
    Issue.record("expected GatewayError")
  }
}

private actor DeleterRecordingTransport: GatewayHTTPTransport {
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

private func deleterResponse(_ json: String) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: 200, body: Data(json.utf8))
}
