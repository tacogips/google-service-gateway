import Foundation
import Testing
@testable import GoogleServiceGatewayCore
import GoogleServiceGatewayReader
import GoogleServiceGatewayWriter
import GoogleServiceGatewayDeleter

private let quotaLimit = "projects/123/services/compute.googleapis.com/consumerQuotaMetrics/compute.googleapis.com%2Fcpus/limits/%2Fproject%2Fregion"

private actor QuotaTransport: GatewayHTTPTransport {
  var responses: [GatewayHTTPResponse]
  var recorded: [GatewayHTTPRequest] = []
  init(_ json: [String], status: Int = 200) {
    responses = json.map { GatewayHTTPResponse(statusCode: status, body: Data($0.utf8)) }
  }
  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !responses.isEmpty else { throw GatewayError(.unexpectedError, "unexpected request") }
    return responses.removeFirst()
  }
  func requests() -> [GatewayHTTPRequest] { recorded }
}

private func quotaClient(_ transport: QuotaTransport) -> GoogleServiceQuotaClient {
  GoogleServiceQuotaClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "private-access-token"))
}

@Test func quotaLimitsResolveProjectIDAndPreserveBucketsAndPagination() async throws {
  let transport = QuotaTransport([
    "{\"name\":\"projects/123\",\"projectId\":\"my-project\"}",
    """
    {"metrics":[{"metric":"compute.googleapis.com/cpus","consumerQuotaLimits":[{"quotaBuckets":[
    {"defaultLimit":"9223372036854775807","effectiveLimit":"8","dimensions":{"region":"us-east1"}}]}]}],"nextPageToken":"next+/="}
    """,
    "{\"metrics\":[{\"metric\":\"compute.googleapis.com/disks_total_storage\"}]}"
  ])
  let page = try await quotaClient(transport).limits(project: "my-project", service: "compute.googleapis.com", pagination: .init(allPages: true))
  #expect(page.kind == .limits)
  #expect(page.dataStatus == .reported)
  #expect(page.records.count == 2)
  #expect(page.pagesFetched == 2)
  #expect(page.nextPageToken == nil)
  let encoded = try GatewayJSONCodec.encode(page)
  #expect(String(bytes: encoded, encoding: .utf8)?.contains("9223372036854775807") == true)
  let requests = await transport.requests()
  #expect(requests[0].url.host == "cloudresourcemanager.googleapis.com")
  #expect(requests[1].url.path == "/v1beta1/projects/123/services/compute.googleapis.com/consumerQuotaMetrics")
  let query = URLComponents(url: requests[2].url, resolvingAgainstBaseURL: false)?.queryItems
  #expect(query?.contains(URLQueryItem(name: "view", value: "FULL")) == true)
  #expect(query?.contains(URLQueryItem(name: "pageToken", value: "next+/=")) == true)
  #expect(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
}

@Test(arguments: QuotaUsageMetric.allCases)
func quotaUsageUsesMonitoringForAnyService(metric: QuotaUsageMetric) async throws {
  let transport = QuotaTransport(["{\"timeSeries\":[{\"points\":[{\"value\":{\"int64Value\":\"50\"}}]}]}"])
  let page = try await quotaClient(transport).usage(.init(
    project: "123", service: "gmail.googleapis.com", metric: metric,
    startTime: Date(timeIntervalSince1970: 100), endTime: Date(timeIntervalSince1970: 200)
  ))
  #expect(page.metric == metric)
  #expect(page.kind == .usage)
  let request = try #require(await transport.requests().first)
  #expect(request.url.host == "monitoring.googleapis.com")
  let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
  let filter = try #require(items.first { $0.name == "filter" }?.value)
  #expect(filter.contains(metric.metricType))
  #expect(filter.contains("resource.labels.service = \"gmail.googleapis.com\""))
  #expect(items.contains(URLQueryItem(name: "interval.startTime", value: "1970-01-01T00:01:40Z")))
}

@Test func quotaEmptyAndPartialResponsesAreNotReportedAsZeroUsage() async throws {
  let transport = QuotaTransport(["{}", "{\"timeSeries\":[],\"executionErrors\":[{\"code\":13,\"message\":\"partial failure\"}]}"])
  let request = QuotaUsageRequest(project: "123", service: "youtube.googleapis.com", startTime: Date(timeIntervalSince1970: 1), endTime: Date())
  let empty = try await quotaClient(transport).usage(request)
  #expect(empty.dataStatus == .noData)
  await #expect(throws: GatewayError.self) { try await quotaClient(transport).usage(request) }
}

@Test func quotaPaginationRejectsRepeatedTokensAndMalformedRecords() async throws {
  let transport = QuotaTransport(["{\"metrics\":[],\"nextPageToken\":\"loop\"}", "{\"metrics\":[],\"nextPageToken\":\"loop\"}"])
  await #expect(throws: GatewayError.self) {
    try await quotaClient(transport).limits(project: "123", service: "youtube.googleapis.com", pagination: .init(allPages: true))
  }
  let invalid = QuotaTransport(["{\"metrics\":[1]}"])
  await #expect(throws: GatewayError.self) { try await quotaClient(invalid).limits(project: "123", service: "gmail.googleapis.com") }
}

@Test func quotaOverrideMutationPreservesEncodedResourceAndWaitsForCompletion() async throws {
  let transport = QuotaTransport([
    "{\"name\":\"operations/create\",\"done\":true,\"response\":{\"overrideValue\":\"8\"}}",
    "{\"name\":\"operations/update\",\"done\":false}",
    "{\"name\":\"operations/update\",\"done\":true,\"response\":{\"overrideValue\":\"9\"}}",
    "{\"name\":\"operations/delete\",\"done\":true}"
  ])
  let client = quotaClient(transport)
  _ = try await client.createOverride(limit: quotaLimit, value: 8, dimensions: ["region": "us-east1"])
  _ = try await client.updateOverride(name: quotaLimit + "/consumerOverrides/abc", value: 9, options: .init(pollInterval: 0.01))
  _ = try await client.deleteOverride(name: quotaLimit + "/consumerOverrides/abc")
  let requests = await transport.requests()
  #expect(requests.map(\.method) == ["POST", "PATCH", "GET", "DELETE"])
  #expect(requests[0].url.absoluteString.contains("compute.googleapis.com%2Fcpus"))
  #expect(!requests[0].url.absoluteString.contains("%252F"))
  let body = try #require(requests[0].body)
  #expect(try GatewayJSONCodec.decode(body) == .object([
    "overrideValue": .string("8"), "dimensions": .object(["region": .string("us-east1")])
  ]))
  #expect(requests[1].url.query == "updateMask=overrideValue")
  #expect(requests[2].url.path == "/v1beta1/operations/update")
  #expect(requests[3].body == nil)
  #expect(requests.allSatisfy { !($0.url.query?.contains("force") ?? false) })
}

@Test func quotaOperationFailureAndNoWaitAreDistinct() async throws {
  let transport = QuotaTransport([
    "{\"name\":\"operations/fail\",\"done\":true,\"error\":{\"code\":9,\"message\":\"safety check failed\"}}",
    "{\"name\":\"operations/pending\"}"
  ])
  await #expect(throws: GatewayError.self) { try await quotaClient(transport).deleteOverride(name: quotaLimit + "/consumerOverrides/x") }
  let pending = try await quotaClient(transport).createOverride(limit: quotaLimit, value: 8, options: .init(wait: false))
  guard case .object(let object) = pending else { Issue.record("Expected operation envelope"); return }
  #expect(object["waited"] == .bool(false))
  #expect(await transport.requests().count == 2)
}

@Test func quotaErrorsRedactCredentialAndRetainProviderDetails() async throws {
  let transport = QuotaTransport(["{\"error\":{\"message\":\"private-access-token\",\"status\":\"PERMISSION_DENIED\"}}"], status: 403)
  do {
    _ = try await quotaClient(transport).limits(project: "123", service: "gmail.googleapis.com")
    Issue.record("Expected rejection")
  } catch let error as GatewayError {
    #expect(error.code == .permissionDenied)
    #expect(error.httpStatus == 403)
    let encoded = try GatewayJSONCodec.encode(error)
    #expect(String(bytes: encoded, encoding: .utf8)?.contains("private-access-token") == false)
  }
}

@Test(arguments: [
  ["quotas", "limits", "--service", "gmail.googleapis.com", "--page-size", "0"],
  ["quotas", "usage", "--service", "youtube.googleapis.com", "--metric", "unknown"],
  ["quotas", "usage", "--service", "gmail.googleapis.com", "--start", "tomorrow"],
  ["quotas", "limits", "--all-pages", "--page-token", "token"],
  ["quotas", "limits", "--project", "123", "--project", "456"],
  ["quotas", "overrides", "delete", "--name", "invalid"],
  ["quotas", "limits", "--oauth-profile", "personal", "--access-token-env", "TOKEN"]
])
func quotaReaderRejectsInvalidOptionsWithoutNetwork(arguments: [String]) async {
  let transport = QuotaTransport([])
  let result = await ReaderAdapter(transport: transport).run(arguments: arguments, environment: [:])
  #expect(result.isError)
  #expect(await transport.requests().isEmpty)
}

@Test func quotaRolesRouteExistingAuthenticationAndRejectUnsafeResources() async throws {
  let transport = QuotaTransport(["{\"metrics\":[]}", "{\"name\":\"operations/new\",\"done\":true}", "{\"name\":\"operations/removed\",\"done\":true}"])
  let environment = ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "private-access-token"]
  let reader = await ReaderAdapter(transport: transport).run(arguments: ["quotas", "limits", "--project", "123", "--service", "gmail"], environment: environment)
  #expect(!reader.isError)
  let writer = await WriterAdapter(transport: transport).run(arguments: ["quotas", "overrides", "create", "--limit", quotaLimit, "--value", "10"], environment: environment)
  #expect(!writer.isError)
  let deleter = await DeleterAdapter(transport: transport).run(arguments: ["quotas", "overrides", "delete", "--name", quotaLimit + "/consumerOverrides/x"], environment: environment)
  #expect(!deleter.isError)
  for resource in [quotaLimit + "?force=true", quotaLimit + "/../x", quotaLimit.replacingOccurrences(of: "%2Fcpus", with: "%")] {
    await #expect(throws: GatewayError.self) { try await quotaClient(transport).createOverride(limit: resource, value: 0) }
  }
  #expect(await transport.requests().count == 3)
}
