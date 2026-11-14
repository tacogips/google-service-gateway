import Foundation
import Testing
@testable import GoogleServiceGatewayCore
@testable import GoogleServiceGatewayReader
@testable import GoogleServiceGatewayWriter

@Test func validationAcceptsAndRejectsEveryDocumentedBoundaryClass() throws {
  let maximumProjectID = "a" + String(repeating: "b", count: 28) + "1"
  for value in ["a12345", maximumProjectID, "1", String(repeating: "9", count: 30)] {
    #expect(try GatewayValidation.project(value) == "projects/\(value)")
  }
  for value in ["a1234", maximumProjectID + "1", "0", "0" + String(repeating: "1", count: 29), String(repeating: "9", count: 31), "a%2Fbcd", " a12345"] {
    #expect(throws: GatewayError.self) { try GatewayValidation.project(value) }
  }

  let maximumLabel = String(repeating: "a", count: 63) + ".googleapis.com"
  #expect(try GatewayValidation.service(maximumLabel) == maximumLabel)
  #expect(try GatewayValidation.service("PRIVATE.EXAMPLE.GOOGLEAPIS.COM") == "private.example.googleapis.com")
  for value in [String(repeating: "a", count: 64) + ".googleapis.com", "-a.googleapis.com", "a-.googleapis.com", "a..googleapis.com", "a.googleapis.com/path", "a%2Eb.googleapis.com"] {
    #expect(throws: GatewayError.self) { try GatewayValidation.service(value) }
  }

  for value in ["operations/a:b@c%", "operations/日本語", "operations/" + String(repeating: "x", count: 300)] {
    #expect(try GatewayValidation.operation(value) == value)
  }
  for value in ["operation/x", "operations/", "operations/a/b", "operations/a?b", "operations/a#b", "operations/a\u{7F}", "operations/a\n"] {
    #expect(throws: GatewayError.self) { try GatewayValidation.operation(value) }
  }

  #expect(try GatewayValidation.tokenEnvironmentName("_") == "_")
  let maximumEnvironmentName = "_" + String(repeating: "A", count: 127)
  #expect(try GatewayValidation.tokenEnvironmentName(maximumEnvironmentName) == maximumEnvironmentName)
  for value in ["", "1TOKEN", "TOKEN-NAME", "TOKEN NAME", maximumEnvironmentName + "A"] {
    #expect(throws: GatewayError.self) { try GatewayValidation.tokenEnvironmentName(value) }
  }
}

@Test func pageSizeBoundsAndDisabledFilterAreTransportVisible() async throws {
  let transport = ReviewTransport(steps: [
    .response(reviewResponse("{\"services\":[]}")),
    .response(reviewResponse("{\"services\":[]}")),
    .response(reviewResponse("{\"services\":[]}"))
  ])
  let client = reviewClient(transport)
  _ = try await client.listServices(.init(project: "123", state: .disabled, pageSize: 1))
  _ = try await client.listServices(.init(project: "123", pageSize: 200))

  let invalidTransport = ReviewTransport(steps: [])
  let invalidClient = reviewClient(invalidTransport)
  for size in [0, 201] {
    await #expect(throws: GatewayError.self) {
      _ = try await invalidClient.listServices(.init(project: "123", pageSize: size))
    }
  }

  let requests = await transport.requests()
  #expect(requests.count == 2)
  let disabledItems = URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems
  #expect(disabledItems?.contains(URLQueryItem(name: "pageSize", value: "1")) == true)
  #expect(disabledItems?.contains(URLQueryItem(name: "filter", value: "state:DISABLED")) == true)
  let maximumItems = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems
  #expect(maximumItems?.contains(URLQueryItem(name: "pageSize", value: "200")) == true)
  #expect(await invalidTransport.requests().isEmpty)
}

@Test func returnedPageTokensUseTheInputByteAndControlContract() async throws {
  let maximumToken = String(repeating: "t", count: 4096)
  let validTransport = ReviewTransport(steps: [.response(reviewListResponse(nextPageToken: maximumToken))])
  let valid = try await reviewClient(validTransport).listServices(.init(project: "123"))
  #expect(valid.nextPageToken == maximumToken)

  for token in [String(repeating: "t", count: 4097), "bad\u{7F}token", "bad\ntoken"] {
    let transport = ReviewTransport(steps: [.response(reviewListResponse(nextPageToken: token))])
    do {
      _ = try await reviewClient(transport).listServices(.init(project: "123", allPages: true))
      Issue.record("Expected malformed returned page token")
    } catch let error as GatewayError {
      #expect(error.code == .malformedResponse)
    } catch {
      Issue.record("Unexpected error type")
    }
    #expect(await transport.requests().count == 1)
  }
}

@Test func batchLimitsAndNormalizedDuplicatesAreRejectedAtomically() async throws {
  let acceptedTransport = ReviewTransport(steps: [
    .response(reviewResponse("{\"name\":\"operations/one\",\"done\":false}")),
    .response(reviewResponse("{\"name\":\"operations/twenty\",\"done\":false}"))
  ])
  let acceptedClient = reviewClient(acceptedTransport)
  _ = try await acceptedClient.batchEnable(project: "123", services: ["gmail"], options: .init(wait: false))
  let twenty = (0..<20).map { "service\($0).googleapis.com" }
  _ = try await acceptedClient.batchEnable(project: "123", services: twenty, options: .init(wait: false))
  #expect(await acceptedTransport.requests().count == 2)

  let rejectedTransport = ReviewTransport(steps: [])
  let rejectedClient = reviewClient(rejectedTransport)
  for services in [[], (0..<21).map { "service\($0).googleapis.com" }, ["gmail", "gmail.googleapis.com"]] {
    await #expect(throws: GatewayError.self) {
      _ = try await rejectedClient.batchEnable(project: "123", services: services, options: .init(wait: false))
    }
  }
  #expect(await rejectedTransport.requests().isEmpty)
}

@Test func disableRequestDefaultsAreExplicitAndSafe() async throws {
  let transport = ReviewTransport(steps: [.response(reviewResponse("{\"name\":\"operations/disable\",\"done\":false}"))])
  let result = try await reviewClient(transport).disable(project: "123", service: "gmail", options: .init(wait: false))
  #expect(result.disableDependentServices == false)
  #expect(result.checkUsage == "SKIP")
  let request = try #require(await transport.requests().first)
  let body = try #require(request.body)
  let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
  #expect(object["disableDependentServices"] as? Bool == false)
  #expect(object["checkIfServiceHasUsage"] as? String == "SKIP")
}

@Test func mutationAndPollTransportFailuresAreNeverRetried() async {
  let initialTransport = ReviewTransport(steps: [.failure(GatewayError(.providerError, "initial failed"))])
  await #expect(throws: GatewayError.self) {
    _ = try await reviewClient(initialTransport).enable(project: "123", service: "gmail", options: .init(wait: false))
  }
  #expect(await initialTransport.requests().count == 1)

  let pollTransport = ReviewTransport(steps: [
    .response(reviewResponse("{\"name\":\"operations/poll\",\"done\":false}")),
    .failure(GatewayError(.providerError, "poll failed"))
  ])
  await #expect(throws: GatewayError.self) {
    _ = try await reviewClient(pollTransport, sleeper: ImmediateSleeper(), clock: ConstantClock()).enable(
      project: "123",
      service: "gmail",
      options: .init(wait: true, pollInterval: 1, timeout: 10)
    )
  }
  #expect(await pollTransport.requests().count == 2)
}

@Test func deadlineEqualityPreventsSleepAndPollRequest() async {
  let clock = SequenceClock(values: [0, 1])
  let sleeper = RecordingSleeper()
  let transport = ReviewTransport(steps: [.response(reviewResponse("{\"name\":\"operations/deadline\",\"done\":false}"))])
  do {
    _ = try await reviewClient(transport, sleeper: sleeper, clock: clock).enable(
      project: "123",
      service: "gmail",
      options: .init(wait: true, pollInterval: 1, timeout: 1)
    )
    Issue.record("Expected timeout at deadline equality")
  } catch let error as GatewayError {
    #expect(error.code == .operationTimeout)
  } catch {
    Issue.record("Unexpected error type")
  }
  #expect(await sleeper.values().isEmpty)
  #expect(await transport.requests().count == 1)
}

@Test func readerConfigurationPrecedenceAndOperationIsolationAreDeterministic() async throws {
  let transport = ReviewTransport(steps: [
    .response(reviewResponse("{\"services\":[]}")),
    .response(reviewResponse("{\"services\":[]}")),
    .response(reviewResponse("{\"services\":[]}")),
    .response(reviewResponse("{\"name\":\"operations/isolated\",\"done\":false}"))
  ])
  let adapter = ReaderAdapter(transport: transport)
  let baseEnvironment = [
    "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "default-token",
    "CUSTOM_TOKEN": "custom-token",
    "GOOGLE_SERVICE_GATEWAY_PROJECT": "222",
    "GOOGLE_CLOUD_PROJECT": "333"
  ]
  _ = await adapter.run(arguments: ["services", "list", "--project", "111"], environment: baseEnvironment)
  _ = await adapter.run(arguments: ["services", "list"], environment: baseEnvironment)
  _ = await adapter.run(
    arguments: ["services", "list", "--access-token-env", "CUSTOM_TOKEN"],
    environment: ["CUSTOM_TOKEN": "custom-token", "GOOGLE_CLOUD_PROJECT": "333"]
  )
  let operation = await adapter.run(
    arguments: ["operations", "get", "--operation", "operations/isolated"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "default-token"]
  )
  #expect(!operation.isError)

  let requests = await transport.requests()
  #expect(requests.map(\.url.path).contains { $0.contains("/projects/111/") })
  #expect(requests.map(\.url.path).contains { $0.contains("/projects/222/") })
  #expect(requests.map(\.url.path).contains { $0.contains("/projects/333/") })
  #expect(requests[2].headers["Authorization"] == "Bearer custom-token")
  #expect(requests[3].url.path == "/v1/operations/isolated")

  let isolatedTransport = ReviewTransport(steps: [])
  let rejected = await ReaderAdapter(transport: isolatedTransport).run(
    arguments: ["operations", "get", "--operation", "operations/x", "--project", "111"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token"]
  )
  #expect(rejected.exitStatus == 2)
  #expect(await isolatedTransport.requests().isEmpty)
}

@Test func cliHelpVersionPrettyAndExitContractsAreExact() async throws {
  let readerHelp = await ReaderAdapter().run(arguments: ["--help"], environment: [:])
  let writerHelp = await WriterAdapter().run(arguments: ["--help"], environment: [:])
  #expect(readerHelp.exitStatus == 0 && !readerHelp.isError)
  #expect(writerHelp.exitStatus == 0 && !writerHelp.isError)
  #expect(readerHelp.output.contains("services list") && !readerHelp.output.contains("batch-enable"))
  #expect(writerHelp.output.contains("batch-enable") && !writerHelp.output.contains("services list"))
  let readerVersion = await ReaderAdapter().run(arguments: ["--version"], environment: [:])
  let writerVersion = await WriterAdapter().run(arguments: ["--version"], environment: [:])
  #expect(readerVersion.output == Version.current)
  #expect(writerVersion.output == Version.current)

  let prettyTransport = ReviewTransport(steps: [.response(reviewResponse("{\"services\":[]}"))])
  let pretty = await ReaderAdapter(transport: prettyTransport).run(
    arguments: ["services", "list", "--pretty"],
    environment: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token", "GOOGLE_SERVICE_GATEWAY_PROJECT": "123"]
  )
  #expect(pretty.exitStatus == 0 && !pretty.isError)
  #expect(pretty.output.contains("\n  \"command\""))
  #expect(try GatewayJSONCodec.decode(Data(pretty.output.utf8)) != .null)

  let exitContracts: [(GatewayErrorCode, Int32)] = [
    (.unexpectedError, 1), (.cancelled, 1), (.invalidArgument, 2), (.configurationError, 3),
    (.authRequired, 3), (.authenticationFailed, 4), (.permissionDenied, 4), (.notFound, 4),
    (.failedPrecondition, 4), (.rateLimited, 4), (.providerError, 4), (.malformedResponse, 4),
    (.operationFailed, 5), (.operationTimeout, 6)
  ]
  for (code, status) in exitContracts { #expect(code.exitStatus == status) }
}

@Test func optionalGatewayFieldsAreOmittedInsteadOfEncodedAsNull() throws {
  let list = ServiceListResult(project: "projects/123", services: [], pagesFetched: 1, nextPageToken: nil)
  let listObject = try reviewObject(GatewayJSONCodec.decode(GatewayJSONCodec.encode(list)))
  #expect(listObject["nextPageToken"] == nil)

  let operation = GatewayOperation(name: "operations/x", done: false)
  let operationObject = try reviewObject(operation.gatewayJSONValue())
  #expect(operationObject["metadata"] == nil)
  #expect(operationObject["response"] == nil)
  #expect(operationObject["error"] == nil)

  let errorObject = try reviewObject(GatewayError(.providerError, "failed").gatewayJSONValue())
  for key in ["httpStatus", "googleCode", "googleStatus", "operationName", "details"] {
    #expect(errorObject[key] == nil)
  }
}

@Test func malformedOperationShapesAreRejectedIndependently() async {
  let shapes = [
    "{\"name\":\"operations/x\",\"metadata\":[]}",
    "{\"name\":\"operations/x\",\"metadata\":null}",
    "{\"name\":\"operations/x\",\"done\":true,\"response\":[]}",
    "{\"name\":\"operations/x\",\"done\":true,\"response\":1}",
    "{\"name\":\"operations/x\",\"done\":false,\"response\":{}}",
    "{\"name\":\"operations/x\",\"done\":false,\"error\":{\"code\":1,\"message\":\"x\"}}",
    "{\"name\":\"operations/x\",\"done\":true,\"response\":{},\"error\":{\"code\":1,\"message\":\"x\"}}",
    "{\"name\":\"operations/x\",\"done\":true,\"error\":{\"code\":\"1\",\"message\":\"x\"}}"
  ]
  for shape in shapes {
    let transport = ReviewTransport(steps: [.response(reviewResponse(shape))])
    do {
      _ = try await reviewClient(transport).getOperation("operations/x")
      Issue.record("Expected malformed operation shape")
    } catch let error as GatewayError {
      #expect(error.code == .malformedResponse)
    } catch {
      Issue.record("Unexpected error type")
    }
  }
}

@Test func duplicateObjectKeysAreRejectedAtEveryJSONBoundary() async {
  #expect(throws: GatewayError.self) {
    try GatewayJSONCodec.decode(Data("{\"key\":1,\"key\":2}".utf8))
  }
  #expect(throws: GatewayError.self) {
    try GatewayJSONCodec.decode(Data("{\"outer\":{\"key\":1,\"key\":2}}".utf8))
  }
  let transport = ReviewTransport(steps: [.response(reviewResponse("{\"services\":[],\"services\":[]}"))])
  do {
    _ = try await reviewClient(transport).listServices(.init(project: "123"))
    Issue.record("Expected duplicate provider keys to fail")
  } catch let error as GatewayError {
    #expect(error.code == .malformedResponse)
  } catch {
    Issue.record("Unexpected error type")
  }
}

@Test func typedTransportErrorsAndProviderStatusAreRecursivelyRedacted() async throws {
  let token = "active-recognizable-token"
  let typedError = GatewayError(
    .providerError,
    "message \(token)",
    googleStatus: "STATUS-\(token)",
    operationName: "operations/\(token)",
    details: [.object(["key-\(token)": .string(token), "credentialData": .string("secret")])]
  )
  let typedTransport = ReviewTransport(steps: [.failure(typedError)])
  do {
    _ = try await reviewClient(typedTransport, token: token).listServices(.init(project: "123"))
    Issue.record("Expected typed transport failure")
  } catch let error as GatewayError {
    let output = String(decoding: try GatewayJSONCodec.encode(error), as: UTF8.self)
    #expect(!output.contains(token))
    #expect(error.googleStatus == "STATUS-<redacted>")
    #expect(error.operationName == "operations/<redacted>")
    #expect(output.contains("key-<redacted>"))
  } catch {
    Issue.record("Unexpected error type")
  }

  let providerBody = try GatewayJSONCodec.encode(.object([
    "error": .object([
      "code": .number("403"),
      "message": .string("provider \(token)"),
      "status": .string("PERMISSION_\(token)_DENIED"),
      "details": .array([.object(["provider-\(token)": .string(token)])])
    ])
  ]))
  let providerTransport = ReviewTransport(steps: [.response(GatewayHTTPResponse(statusCode: 403, body: providerBody))])
  do {
    _ = try await reviewClient(providerTransport, token: token).listServices(.init(project: "123"))
    Issue.record("Expected provider failure")
  } catch let error as GatewayError {
    let output = String(decoding: try GatewayJSONCodec.encode(error), as: UTF8.self)
    #expect(error.code == .permissionDenied)
    #expect(error.googleStatus == "PERMISSION_<redacted>_DENIED")
    #expect(!output.contains(token))
  } catch {
    Issue.record("Unexpected error type")
  }
}

@Test func successfulOperationPayloadValuesArePreserved() async throws {
  let token = "active-token"
  let body = try GatewayJSONCodec.encode(.object([
    "name": .string("operations/x"),
    "done": .bool(true),
    "error": .object([
      "code": .number("7"),
      "message": .string("denied \(token)"),
      "details": .array([.object(["key-\(token)": .string(token)])])
    ])
  ]))
  let transport = ReviewTransport(steps: [.response(GatewayHTTPResponse(statusCode: 200, body: body))])
  let result = try await reviewClient(transport, token: token).getOperation("operations/x")
  let output = String(decoding: try GatewayJSONCodec.encode(result), as: UTF8.self)
  #expect(output.contains(token))
  #expect(output.contains("key-active-token"))
}

private enum ReviewStep: Sendable {
  case response(GatewayHTTPResponse)
  case failure(GatewayError)
}

private actor ReviewTransport: GatewayHTTPTransport {
  private var steps: [ReviewStep]
  private var recorded: [GatewayHTTPRequest] = []

  init(steps: [ReviewStep]) { self.steps = steps }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !steps.isEmpty else { throw GatewayError(.unexpectedError, "missing review response") }
    switch steps.removeFirst() {
    case .response(let response): return response
    case .failure(let error): throw error
    }
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private struct ImmediateSleeper: GatewaySleeper {
  func sleep(for seconds: TimeInterval) async throws {}
}

private actor RecordingSleeper: GatewaySleeper {
  private var recorded: [TimeInterval] = []
  func sleep(for seconds: TimeInterval) async throws { recorded.append(seconds) }
  func values() -> [TimeInterval] { recorded }
}

private struct ConstantClock: GatewayClock {
  func now() -> TimeInterval { 0 }
}

private final class SequenceClock: GatewayClock, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [TimeInterval]

  init(values: [TimeInterval]) { self.values = values }

  func now() -> TimeInterval {
    lock.withLock {
      guard values.count > 1 else { return values.first ?? 0 }
      return values.removeFirst()
    }
  }
}

private func reviewClient(
  _ transport: ReviewTransport,
  token: String = "token",
  sleeper: any GatewaySleeper = ImmediateSleeper(),
  clock: any GatewayClock = ConstantClock()
) -> GoogleServiceGatewayClient {
  GoogleServiceGatewayClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: token),
    sleeper: sleeper,
    clock: clock
  )
}

private func reviewResponse(_ json: String, status: Int = 200) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: Data(json.utf8))
}

private func reviewListResponse(nextPageToken: String) -> GatewayHTTPResponse {
  let data = try? GatewayJSONCodec.encode(.object([
    "services": .array([]),
    "nextPageToken": .string(nextPageToken)
  ]))
  return GatewayHTTPResponse(statusCode: 200, body: data ?? Data())
}

private func reviewObject(_ value: JSONValue) throws -> [String: JSONValue] {
  guard case .object(let object) = value else {
    throw GatewayError(.unexpectedError, "test expected object")
  }
  return object
}
