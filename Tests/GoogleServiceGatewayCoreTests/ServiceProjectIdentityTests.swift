import Foundation
import Testing
@testable import GoogleServiceGatewayCore

@Test func serviceListResolvesProjectIDToNumberAndKeepsExactValidation() async throws {
  let transport = RecordingTransport(responses: [
    response(#"{"name":"projects/123","projectId":"gateway-test-123"}"#),
    response(#"{"services":[{"name":"projects/123/services/gmail.googleapis.com","state":"ENABLED","config":{"name":"gmail.googleapis.com"}}]}"#)
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "fixture-token"))
  let result = try await client.listServices(.init(project: "gateway-test-123", state: .enabled))
  #expect(result.project == "projects/123")
  #expect(result.services.count == 1)
  let requests = await transport.requests()
  #expect(requests.count == 2)
  #expect(requests[0].url.host == "cloudresourcemanager.googleapis.com")
  #expect(requests[0].url.path == "/v3/projects/gateway-test-123")
  #expect(requests[1].url.path == "/v1/projects/123/services")
}

@Test func serviceGetResolvesProjectIDBeforeServiceUsageRequest() async throws {
  let transport = RecordingTransport(responses: [
    response(#"{"name":"projects/123","projectId":"gateway-test-123"}"#),
    response(#"{"name":"projects/123/services/gmail.googleapis.com","state":"ENABLED","config":{"name":"gmail.googleapis.com"}}"#)
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "fixture-token"))
  let result = try await client.getService(project: "gateway-test-123", service: "gmail")
  #expect(result.project == "projects/123")
  #expect(await transport.requests().last?.url.path == "/v1/projects/123/services/gmail.googleapis.com")
}

@Test(arguments: [
  #"{"name":"projects/123","projectId":"another-project"}"#,
  #"{"name":"projects/not-a-number","projectId":"gateway-test-123"}"#,
  #"{"name":"folders/123","projectId":"gateway-test-123"}"#
]) func mismatchedProjectIdentityNeverDispatchesServiceUsage(body: String) async throws {
  let transport = RecordingTransport(responses: [response(body)])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "fixture-token"))
  await #expect(throws: GatewayError.self) { _ = try await client.listServices(.init(project: "gateway-test-123", state: .enabled)) }
  #expect(await transport.requests().count == 1)
}

@Test func projectResolutionDoesNotAcceptOtherProjectServiceResponses() async throws {
  let transport = RecordingTransport(responses: [
    response(#"{"name":"projects/123","projectId":"gateway-test-123"}"#),
    response(#"{"services":[{"name":"projects/456/services/gmail.googleapis.com","state":"ENABLED"}]}"#)
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "fixture-token"))
  await #expect(throws: GatewayError.self) { _ = try await client.listServices(.init(project: "gateway-test-123", state: .enabled)) }
}

@Test func serviceListAcceptsMarketplaceCatalogResponseNames() async throws {
  let service = "marketplace-api.endpoints.vendor-project.cloud.goog"
  let transport = RecordingTransport(responses: [
    response("{\"services\":[{\"name\":\"projects/123/services/\(service)\",\"state\":\"DISABLED\"}]}")
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "fixture-token"))
  let result = try await client.listServices(.init(project: "123"))
  #expect(result.services.first?.serviceId == service)
  #expect(throws: GatewayError.self) { try GatewayValidation.service(service) }
}

@Test(arguments: ["bad..example", "bad.example?token=x", "UPPER.example", "bad_example.com", "localhost"])
func serviceListRejectsMalformedCatalogResponseNames(service: String) async throws {
  let transport = RecordingTransport(responses: [
    response("{\"services\":[{\"name\":\"projects/123/services/\(service)\",\"state\":\"DISABLED\"}]}")
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "fixture-token"))
  do {
    _ = try await client.listServices(.init(project: "123"))
    Issue.record("Expected invalid catalog name to fail")
  } catch let error as GatewayError {
    #expect(error.code == .malformedResponse)
  }
}

private actor RecordingTransport: GatewayHTTPTransport {
  private var captured: [GatewayHTTPRequest] = []
  private var responses: [GatewayHTTPResponse]

  init(responses: [GatewayHTTPResponse]) { self.responses = responses }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    captured.append(request)
    guard !responses.isEmpty else { throw GatewayError(.providerError, "No fixture response available") }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { captured }
}

private func response(_ json: String) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: 200, body: Data(json.utf8))
}
