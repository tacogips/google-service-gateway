import Foundation
import Testing
@testable import GoogleServiceGatewayCore

private actor BillingRegressionTransport: GatewayHTTPTransport {
  var json: [String]
  init(_ json: [String]) { self.json = json }
  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    guard !json.isEmpty else { throw GatewayError(.unexpectedError, "unexpected request") }
    return GatewayHTTPResponse(statusCode: 200, body: Data(json.removeFirst().utf8))
  }
}

@Test func billingTopLevelAccountAcceptsEmptyParentAccount() async throws {
  let transport = BillingRegressionTransport(["""
    {"billingAccounts":[{"name":"billingAccounts/ABCDEF-123456-789012","displayName":"Primary","open":true,"masterBillingAccount":""}]}
    """])
  let client = GoogleCloudBillingClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let page = try await client.listAccounts()
  #expect(page.accounts.count == 1)
  #expect(page.accounts.first?.parentBillingAccount == nil)
}

@Test func billingProjectNumberResolvesExactProjectID() async throws {
  let transport = BillingRegressionTransport([
    "{\"name\":\"projects/123\",\"projectId\":\"my-project\"}",
    "{\"projectId\":\"my-project\",\"billingEnabled\":false}"
  ])
  let client = GoogleCloudBillingClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let project = try await client.getProjectBilling("123")
  #expect(project.projectID == "my-project")
  #expect(!project.billingEnabled)
}

@Test func billingProjectNumberRejectsIdentityMismatch() async {
  let transport = BillingRegressionTransport(["{\"name\":\"projects/999\",\"projectId\":\"my-project\"}"])
  let client = GoogleCloudBillingClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  await #expect(throws: GatewayError.self) { try await client.getProjectBilling("123") }
}
