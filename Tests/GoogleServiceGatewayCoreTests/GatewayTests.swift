import Foundation
import Testing
@testable import GoogleServiceGatewayCore
@testable import GoogleServiceGatewayReader
@testable import GoogleServiceGatewayWriter

@Test func aliasesAndValidationAreNormalized() throws {
  #expect(try GatewayValidation.project("123") == "projects/123")
  #expect(try GatewayValidation.project("projects/my-project-1") == "projects/my-project-1")
  #expect(try GatewayValidation.service("GMAIL") == "gmail.googleapis.com")
  #expect(throws: GatewayError.self) { try GatewayValidation.service("gmail.example") }
  #expect(try GatewayValidation.operation("operations/a:b@c") == "operations/a:b@c")
  #expect(throws: GatewayError.self) { try GatewayValidation.operation("operations/a/b") }
  #expect(throws: GatewayError.self) { try GatewayValidation.tokenEnvironmentName("TOKENé") }
}

@Test func listUsesSafeQueryValuesAndPreservesSuccessfulPayload() async throws {
  let transport = RecordingTransport(responses: [response("{\"services\":[{\"name\":\"projects/123/services/gmail.googleapis.com\",\"state\":\"ENABLED\",\"config\":{\"message\":\"recognizable-token\"}}],\"nextPageToken\":\"opaque%token\"}")])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "recognizable-token"))
  let result = try await client.listServices(.init(project: "123", state: .enabled, pageSize: 50, pageToken: "p+1"))
  #expect(result.nextPageToken == "opaque%token")
  let resultJSON = String(data: try GatewayJSONCodec.encode(result), encoding: .utf8) ?? ""
  #expect(resultJSON.contains("recognizable-token"))
  let request = await transport.requests().first
  #expect(request?.method == "GET")
  #expect(request?.headers["Authorization"] == "Bearer recognizable-token")
  let components = URLComponents(url: try #require(request?.url), resolvingAgainstBaseURL: false)
  #expect(components?.queryItems?.contains(URLQueryItem(name: "filter", value: "state:ENABLED")) == true)
  #expect(components?.queryItems?.contains(URLQueryItem(name: "pageToken", value: "p+1")) == true)
}

@Test func allPagesRejectsRepeatedToken() async throws {
  let transport = RecordingTransport(responses: [
    response("{\"services\":[],\"nextPageToken\":\"again\"}"),
    response("{\"services\":[],\"nextPageToken\":\"again\"}")
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  await #expect(throws: GatewayError.self) {
    _ = try await client.listServices(.init(project: "123", allPages: true))
  }
}

@Test func readerRejectsMutationBeforeConfigurationResolution() async {
  let transport = RecordingTransport(responses: [])
  let result = await ReaderAdapter(transport: transport).run(arguments: ["services", "enable", "--service", "gmail"], environment: [:])
  #expect(result.isError)
  #expect(result.exitStatus == 2)
  #expect(await transport.requests().isEmpty)
}

@Test func writerRejectsReadBeforeConfigurationResolution() async {
  let transport = RecordingTransport(responses: [])
  let result = await WriterAdapter(transport: transport).run(arguments: ["services", "list"], environment: [:])
  #expect(result.isError)
  #expect(result.exitStatus == 2)
  #expect(await transport.requests().isEmpty)
}

@Test func writerRejectsNoWaitPollingConflictBeforeTransport() async {
  let transport = RecordingTransport(responses: [])
  let result = await WriterAdapter(transport: transport).run(
    arguments: ["services", "enable", "--service", "gmail", "--no-wait", "--timeout", "2"],
    environment: [:]
  )
  #expect(result.isError)
  #expect(result.exitStatus == 2)
  #expect(await transport.requests().isEmpty)
}

@Test func redactionRemovesTokenAndSensitiveKeys() throws {
  let details: JSONValue = .object(["access_token": .string("recognizable-token"), "nested": .array([.string("safe")])])
  let encoded = try GatewayJSONCodec.encode(Redactor.redact(details))
  let output = String(decoding: encoded, as: UTF8.self)
  #expect(!output.contains("recognizable-token"))
  #expect(Redactor.scrub("error recognizable-token", token: "recognizable-token") == "error <redacted>")
}

@Test func providerErrorsScrubTokensInNonSensitiveDetails() async {
  let token = "recognizable-token"
  let transport = RecordingTransport(responses: [response("{\"error\":{\"code\":403,\"message\":\"safe\",\"status\":\"PERMISSION_DENIED\",\"details\":[{\"message\":\"recognizable-token\"}]}}", status: 403)])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: token))
  do {
    _ = try await client.listServices(.init(project: "123"))
    Issue.record("Expected provider error")
  } catch let error as GatewayError {
    let output = String(data: (try? GatewayJSONCodec.encode(error)) ?? Data(), encoding: .utf8) ?? ""
    #expect(error.code == .permissionDenied)
    #expect(!output.contains(token))
  } catch {
    Issue.record("Unexpected error")
  }
}

@Test func malformedAndUnexpectedFailuresNeverExposeTokenValues() async {
  let token = "recognizable-token"
  let malformed = GoogleServiceGatewayClient(
    transport: RecordingTransport(responses: [response("recognizable-token")]),
    tokenProvider: StaticAccessTokenProvider(token: token)
  )
  let unexpected = GoogleServiceGatewayClient(
    transport: UnexpectedTransport(),
    tokenProvider: StaticAccessTokenProvider(token: token)
  )
  for client in [malformed, unexpected] {
    do {
      _ = try await client.listServices(.init(project: "123"))
      Issue.record("Expected failure")
    } catch let error as GatewayError {
      let output = String(data: (try? GatewayJSONCodec.encode(error)) ?? Data(), encoding: .utf8) ?? ""
      #expect(!output.contains(token))
    } catch {
      Issue.record("Unexpected error type")
    }
  }
}

@Test func mutationsConstructExpectedRequestsAndNoWaitDoesNotPoll() async throws {
  let transport = RecordingTransport(responses: [
    response("{\"name\":\"operations/enable\",\"done\":false}"),
    response("{\"name\":\"operations/disable\",\"done\":false}"),
    response("{\"name\":\"operations/batch\",\"done\":false}")
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let options = MutationOptions(wait: false)
  _ = try await client.enable(project: "123", service: "gmail", options: options)
  _ = try await client.disable(project: "123", service: "drive", disableDependents: true, checkUsage: true, options: options)
  _ = try await client.batchEnable(project: "123", services: ["docs", "sheets"], options: options)
  let requests = await transport.requests()
  #expect(requests.count == 3)
  #expect(requests[0].url.path.hasSuffix("/gmail.googleapis.com:enable"))
  #expect(requests[1].url.path.hasSuffix("/drive.googleapis.com:disable"))
  #expect(requests[2].url.path.hasSuffix("/services:batchEnable"))
  let disableBody = try #require(requests[1].body)
  let object = try #require(JSONSerialization.jsonObject(with: disableBody) as? [String: Any])
  #expect(object["disableDependentServices"] as? Bool == true)
  #expect(object["checkIfServiceHasUsage"] as? String == "CHECK")
}

@Test func invalidPollingOptionsPreventEveryMutationRequest() async {
  let enableTransport = RecordingTransport(responses: [])
  let disableTransport = RecordingTransport(responses: [])
  let batchTransport = RecordingTransport(responses: [])
  let enableClient = GoogleServiceGatewayClient(transport: enableTransport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let disableClient = GoogleServiceGatewayClient(transport: disableTransport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  let batchClient = GoogleServiceGatewayClient(transport: batchTransport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  await #expect(throws: GatewayError.self) {
    _ = try await enableClient.enable(project: "123", service: "gmail", options: .init(pollInterval: 0))
  }
  await #expect(throws: GatewayError.self) {
    _ = try await disableClient.disable(project: "123", service: "drive", options: .init(pollInterval: -1))
  }
  await #expect(throws: GatewayError.self) {
    _ = try await batchClient.batchEnable(project: "123", services: ["docs"], options: .init(timeout: .infinity))
  }
  await #expect(throws: GatewayError.self) {
    _ = try await batchClient.batchEnable(project: "123", services: ["sheets"], options: .init(timeout: .nan))
  }
  #expect(await enableTransport.requests().isEmpty)
  #expect(await disableTransport.requests().isEmpty)
  #expect(await batchTransport.requests().isEmpty)
}

@Test func pollingUsesInjectedClockSleeperAndCompletes() async throws {
  let clock = ScriptedClock(now: 0)
  let sleeper = AdvancingSleeper(clock: clock)
  let transport = RecordingTransport(responses: [
    response("{\"name\":\"operations/op\",\"done\":false}"),
    response("{\"name\":\"operations/op\",\"done\":true,\"response\":{}}")
  ])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"), sleeper: sleeper, clock: clock)
  let result = try await client.enable(project: "123", service: "gmail", options: .init(wait: true, pollInterval: 1, timeout: 5))
  #expect(result.operation.done)
  #expect(await sleeper.sleeps() == [1])
  #expect(await transport.requests().count == 2)
}

@Test func pollingTimesOutAtDeadlineWithoutPollRequest() async throws {
  let clock = ScriptedClock(now: 0)
  let sleeper = AdvancingSleeper(clock: clock)
  let transport = RecordingTransport(responses: [response("{\"name\":\"operations/op\",\"done\":false}")])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"), sleeper: sleeper, clock: clock)
  do {
    _ = try await client.enable(project: "123", service: "gmail", options: .init(wait: true, pollInterval: 2, timeout: 0.5))
    Issue.record("Expected timeout")
  } catch let error as GatewayError {
    #expect(error.code == .operationTimeout)
    #expect(error.operationName == "operations/op")
  }
  #expect(await sleeper.sleeps() == [0.5])
  #expect(await transport.requests().count == 1)
}

@Test func completedInFlightPollMayFinishAfterDeadline() async throws {
  let clock = ScriptedClock(now: 0)
  let transport = DelayedOperationTransport(
    clock: clock,
    responses: [
      response("{\"name\":\"operations/op\",\"done\":false}"),
      response("{\"name\":\"operations/op\",\"done\":true,\"response\":{}}")
    ]
  )
  let client = GoogleServiceGatewayClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: "token"),
    sleeper: AdvancingSleeper(clock: clock),
    clock: clock
  )
  let result = try await client.enable(project: "123", service: "gmail", options: .init(wait: true, pollInterval: 0.1, timeout: 0.5))
  #expect(result.operation.done)
  #expect(await transport.requests().count == 2)
}

@Test func pollingMapsSleeperCancellationToGatewayError() async throws {
  let transport = RecordingTransport(responses: [response("{\"name\":\"operations/op\",\"done\":false}")])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"), sleeper: CancellingSleeper(), clock: ScriptedClock(now: 0))
  do {
    _ = try await client.enable(project: "123", service: "gmail")
    Issue.record("Expected cancellation")
  } catch let error as GatewayError {
    #expect(error.code == .cancelled)
  } catch {
    Issue.record("Unexpected error")
  }
}

@Test func completedOperationErrorMapsToOperationFailed() async throws {
  let transport = RecordingTransport(responses: [response("{\"name\":\"operations/op\",\"done\":true,\"error\":{\"code\":7,\"message\":\"denied\"}}")])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  do {
    _ = try await client.enable(project: "123", service: "gmail", options: .init(wait: false))
    Issue.record("Expected operation failure")
  } catch let error as GatewayError {
    #expect(error.code == .operationFailed)
    #expect(error.operationName == "operations/op")
  }
}

@Test func malformedAndAuthenticationResponsesUseStableErrors() async {
  let malformed = GoogleServiceGatewayClient(
    transport: RecordingTransport(responses: [response("not-json")]),
    tokenProvider: StaticAccessTokenProvider(token: "token")
  )
  await #expect(throws: GatewayError.self) { _ = try await malformed.listServices(.init(project: "123")) }
  let unauthenticated = GoogleServiceGatewayClient(
    transport: RecordingTransport(responses: [response("{\"error\":{\"code\":401,\"message\":\"no\",\"status\":\"UNAUTHENTICATED\"}}", status: 401)]),
    tokenProvider: StaticAccessTokenProvider(token: "token")
  )
  do {
    _ = try await unauthenticated.listServices(.init(project: "123"))
    Issue.record("Expected authentication failure")
  } catch let error as GatewayError {
    #expect(error.code == .authenticationFailed)
    #expect(error.httpStatus == 401)
  } catch {
    Issue.record("Unexpected error")
  }
}

@Test func readerListDefaultsAndAllFilterAreTransportVisible() async throws {
  let transport = RecordingTransport(responses: [response("{\"services\":[]}")])
  let result = await ReaderAdapter(transport: transport).run(
    arguments: ["services", "list"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token", "GOOGLE_SERVICE_GATEWAY_PROJECT": "123"]
  )
  #expect(!result.isError)
  let captured = await transport.requests().first
  let request = try #require(captured)
  let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
  #expect(items?.contains(URLQueryItem(name: "pageSize", value: "50")) == true)
  #expect(items?.contains(where: { $0.name == "filter" }) == false)
}

@Test func readerRejectsListOptionConflictsBeforeTransport() async {
  let transport = RecordingTransport(responses: [])
  let result = await ReaderAdapter(transport: transport).run(
    arguments: ["services", "list", "--page-token", "opaque", "--all-pages"],
    environment: [:]
  )
  #expect(result.isError)
  #expect(result.exitStatus == 2)
  #expect(await transport.requests().isEmpty)
}

@Test func operationSuffixIsEncodedAsOnePathSegment() async throws {
  let transport = RecordingTransport(responses: [response("{\"name\":\"operations/a:b@c%\",\"done\":false}")])
  let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: "token"))
  _ = try await client.getOperation("operations/a:b@c%")
  let captured = await transport.requests().first
  let request = try #require(captured)
  let encodedPath = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath
  #expect(encodedPath?.hasSuffix("operations/a%3Ab%40c%25") == true)
}

@Test func errorEnvelopesRetainRecognizedCommandNames() async {
  let reader = await ReaderAdapter().run(arguments: ["services", "get"], environment: [:])
  let writer = await WriterAdapter().run(arguments: ["services", "enable"], environment: [:])
  #expect(reader.output.contains("\"command\":\"services.get\""))
  #expect(writer.output.contains("\"command\":\"services.enable\""))
}

@Test func jsonValuePreservesArbitraryProviderNumberLexemes() throws {
  for number in [
    "12345678901234567890123456789012345678901234567890",
    "0.12345678901234567890123456789012345678901234567890",
    "1.23456789012345678901234567890e+999"
  ] {
    let value = try GatewayJSONCodec.decode(Data(number.utf8))
    let output = String(data: try GatewayJSONCodec.encode(value), encoding: .utf8)
    #expect(output == number)
  }
}

@Test func coreAndCliPreserveProviderNumbersInResponses() async throws {
  let number = "12345678901234567890123456789012345678901234567890"
  let transport = RecordingTransport(responses: [response("{\"services\":[{\"name\":\"projects/123/services/gmail.googleapis.com\",\"config\":{\"quota\":\(number)}}]}")])
  let result = await ReaderAdapter(transport: transport).run(
    arguments: ["services", "list"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token", "GOOGLE_SERVICE_GATEWAY_PROJECT": "123"]
  )
  #expect(!result.isError)
  #expect(result.output.contains("\"quota\":\(number)"))
}

@Test func successResponsesPreserveJSONEscapedOpaqueValuesInCoreAndCLI() async throws {
  let token = "recognizable\"token\\suffix"
  let body = try JSONSerialization.data(withJSONObject: [
    "services": [[
      "name": "projects/123/services/gmail.googleapis.com",
      "config": ["message": token, "nested": ["value": token]]
    ]]
  ])
  let coreClient = GoogleServiceGatewayClient(
    transport: RecordingTransport(responses: [response(body)]),
    tokenProvider: StaticAccessTokenProvider(token: token)
  )
  let core = try await coreClient.listServices(.init(project: "123"))
  #expect(jsonValueContainsString(core.services[0].config, token))
  let cli = await ReaderAdapter(transport: RecordingTransport(responses: [response(body)])).run(
    arguments: ["services", "list"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": token, "GOOGLE_SERVICE_GATEWAY_PROJECT": "123"]
  )
  #expect(!cli.isError)
  #expect(jsonValueContainsString(try GatewayJSONCodec.decode(Data(cli.output.utf8)), token))
}

@Test func jsonCodecKeepsMarkerLikeStringsAsStrings() throws {
  let original: JSONValue = .object([
    "value": .string("__google_service_gateway_number__:123"),
    "nested": .array([.string("__google_service_gateway_number__:-1.2e3"), .number("123456789012345678901234567890")])
  ])
  let output = try GatewayJSONCodec.encode(original)
  #expect(String(decoding: output, as: UTF8.self).contains("\"value\":\"__google_service_gateway_number__:123\""))
  #expect(try GatewayJSONCodec.decode(output) == original)
  #expect(throws: GatewayError.self) { try GatewayJSONCodec.encode(.number("01")) }
}

@Test func gatewayCodecEncodesResultAndErrorNumbersWithoutLoss() throws {
  let number = "12345678901234567890123456789012345678901234567890"
  let result = ServiceListResult(
    project: "projects/123",
    services: [.init(name: "projects/123/services/gmail.googleapis.com", parent: "projects/123", serviceId: "gmail.googleapis.com", state: .enabled, config: .object(["quota": .number(number)]))],
    pagesFetched: 1,
    nextPageToken: nil
  )
  let error = GatewayError(.providerError, "provider failure", details: [.object(["quota": .number(number)])])
  for encoded in [try GatewayJSONCodec.encode(result), try GatewayJSONCodec.encode(error)] {
    #expect(jsonValueContainsNumber(try GatewayJSONCodec.decode(encoded), number))
  }
}

private actor RecordingTransport: GatewayHTTPTransport {
  private var recorded = [GatewayHTTPRequest]()
  private var responses: [GatewayHTTPResponse]

  init(responses: [GatewayHTTPResponse]) { self.responses = responses }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !responses.isEmpty else { throw GatewayError(.unexpectedError, "no scripted response") }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private final class ScriptedClock: GatewayClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval

  init(now: TimeInterval) { value = now }
  func now() -> TimeInterval { lock.withLock { value } }
  func advance(by duration: TimeInterval) { lock.withLock { value += duration } }
}

private actor AdvancingSleeper: GatewaySleeper {
  private let clock: ScriptedClock
  private var values = [TimeInterval]()

  init(clock: ScriptedClock) { self.clock = clock }
  func sleep(for seconds: TimeInterval) async throws {
    values.append(seconds)
    clock.advance(by: seconds)
  }
  func sleeps() -> [TimeInterval] { values }
}

private struct CancellingSleeper: GatewaySleeper {
  func sleep(for seconds: TimeInterval) async throws { throw CancellationError() }
}

private struct UnexpectedTransport: GatewayHTTPTransport {
  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    throw NSError(domain: "recognizable-token", code: 1)
  }
}

private actor DelayedOperationTransport: GatewayHTTPTransport {
  private let clock: ScriptedClock
  private var responses: [GatewayHTTPResponse]
  private var recorded = [GatewayHTTPRequest]()

  init(clock: ScriptedClock, responses: [GatewayHTTPResponse]) {
    self.clock = clock
    self.responses = responses
  }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    if request.url.path.contains("/v1/operations/") { clock.advance(by: 1) }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private func response(_ json: String, status: Int = 200) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: Data(json.utf8))
}

private func response(_ body: Data, status: Int = 200) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: body)
}

private func jsonValueContainsString(_ value: JSONValue, _ target: String) -> Bool {
  switch value {
  case .object(let object): object.values.contains { jsonValueContainsString($0, target) }
  case .array(let values): values.contains { jsonValueContainsString($0, target) }
  case .string(let string): string.contains(target)
  default: false
  }
}

private func jsonValueContainsNumber(_ value: JSONValue, _ target: String) -> Bool {
  switch value {
  case .object(let object): object.values.contains { jsonValueContainsNumber($0, target) }
  case .array(let values): values.contains { jsonValueContainsNumber($0, target) }
  case .number(let number): number == target
  default: false
  }
}
