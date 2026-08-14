import Foundation
import Testing
@testable import GoogleServiceGatewayCore
@testable import GoogleServiceGatewayReader
@testable import GoogleServiceGatewayWriter

@Test func successfulPaginationPreservesOpaqueValuesOrderAndExhaustion() async throws {
  let opaqueToken = "opaque-active-token-\u{80}-é"
  let transport = FindingTransport(responses: [
    findingResponse("""
    {"services":[{"name":"projects/123/services/gmail.googleapis.com","config":{"opaque":"active-token"}}],"nextPageToken":"\(opaqueToken)"}
    """),
    findingResponse("""
    {"services":[{"name":"projects/123/services/drive.googleapis.com"}],"nextPageToken":"third"}
    """),
    findingResponse("""
    {"services":[{"name":"projects/123/services/docs.googleapis.com"}]}
    """)
  ])
  let result = try await findingClient(transport, token: "active-token").listServices(
    .init(project: "123", allPages: true)
  )

  #expect(result.services.map(\.serviceId) == [
    "gmail.googleapis.com",
    "drive.googleapis.com",
    "docs.googleapis.com"
  ])
  #expect(result.services.first?.config == .object(["opaque": .string("active-token")]))
  #expect(result.pagesFetched == 3)
  #expect(result.nextPageToken == nil)

  let requests = await transport.requests()
  #expect(requests.count == 3)
  #expect(findingQueryValue("pageToken", in: requests[0]) == nil)
  #expect(findingQueryValue("pageToken", in: requests[1]) == opaqueToken)
  #expect(findingQueryValue("pageToken", in: requests[2]) == "third")
}

@Test func operationNamesAreScrubbedOnlyWhenPromotedToErrors() async throws {
  let token = "active-token"
  let success = try await findingClient(
    FindingTransport(responses: [findingResponse(
      "{\"name\":\"operations/active-token\",\"done\":false}"
    )]),
    token: token
  ).getOperation("operations/active-token")
  #expect(success.operation.name == "operations/active-token")

  let failureClient = findingClient(
    FindingTransport(responses: [findingResponse(
      "{\"name\":\"operations/active-token\",\"done\":true,\"error\":{\"code\":7,\"message\":\"denied\"}}"
    )]),
    token: token
  )
  do {
    _ = try await failureClient.enable(
      project: "123",
      service: "gmail",
      options: .init(wait: false)
    )
    Issue.record("Expected operation failure")
  } catch let error as GatewayError {
    #expect(error.code == .operationFailed)
    #expect(error.operationName == "operations/<redacted>")
    #expect(!String(decoding: try GatewayJSONCodec.encode(error), as: UTF8.self).contains(token))
  } catch {
    Issue.record("Unexpected operation failure type")
  }
}

@Test func inputPageTokenUsesUTF8ByteAndASCIIControlBoundaries() async throws {
  let maximumMultibyteToken = String(repeating: "é", count: 2_048)
  #expect(maximumMultibyteToken.lengthOfBytes(using: .utf8) == 4_096)
  #expect(try GatewayValidation.pageToken(maximumMultibyteToken) == maximumMultibyteToken)
  #expect(try GatewayValidation.pageToken("opaque\u{80}value") == "opaque\u{80}value")
  #expect(try GatewayValidation.pageToken(" ") == " ")

  for invalid in [
    "",
    String(repeating: "é", count: 2_049),
    "prefix\u{0}suffix",
    "prefix\u{1F}suffix",
    "prefix\u{7F}suffix"
  ] {
    #expect(throws: GatewayError.self) { try GatewayValidation.pageToken(invalid) }
  }

  let transport = FindingTransport(responses: [findingResponse("{\"services\":[]}")])
  _ = try await findingClient(transport).listServices(
    .init(project: "123", pageToken: maximumMultibyteToken)
  )
  #expect(findingQueryValue("pageToken", in: try #require(await transport.requests().first)) == maximumMultibyteToken)
}

@Test func serviceResponsesMustCorrelateWithRequestedResources() async throws {
  let cases: [(String, String?, String)] = [
    ("list project", nil, "projects/456/services/gmail.googleapis.com"),
    ("get project", "gmail", "projects/456/services/gmail.googleapis.com"),
    ("get service", "gmail", "projects/123/services/drive.googleapis.com")
  ]

  for (label, requestedService, returnedName) in cases {
    let body: String
    if requestedService == nil {
      body = "{\"services\":[{\"name\":\"\(returnedName)\"}]}"
    } else {
      body = "{\"name\":\"\(returnedName)\"}"
    }
    let client = findingClient(FindingTransport(responses: [findingResponse(body)]))
    do {
      if let requestedService {
        _ = try await client.getService(project: "123", service: requestedService)
      } else {
        _ = try await client.listServices(.init(project: "123"))
      }
      Issue.record("Expected resource mismatch for \(label)")
    } catch let error as GatewayError {
      #expect(error.code == .malformedResponse)
    } catch {
      Issue.record("Unexpected error type for \(label)")
    }
  }
}

@Test func enableAndBatchEnableBodiesAreExactAndOrdered() async throws {
  let transport = FindingTransport(responses: [
    findingResponse("{\"name\":\"operations/enable\",\"done\":false}"),
    findingResponse("{\"name\":\"operations/batch\",\"done\":false}")
  ])
  let client = findingClient(transport)
  _ = try await client.enable(
    project: "123",
    service: "gmail",
    options: .init(wait: false)
  )
  _ = try await client.batchEnable(
    project: "123",
    services: ["docs", "sheets.googleapis.com"],
    options: .init(wait: false)
  )

  let requests = await transport.requests()
  #expect(requests.map(\.method) == ["POST", "POST"])
  #expect(try findingDecodedBody(requests[0]) == .object([:]))
  #expect(try findingDecodedBody(requests[1]) == .object([
    "serviceIds": .array([
      .string("docs.googleapis.com"),
      .string("sheets.googleapis.com")
    ])
  ]))
}

@Test func documentedHTTPAndGoogleStatusMappingsAreComplete() async {
  let httpCases: [(Int, GatewayErrorCode)] = [
    (401, .authenticationFailed),
    (403, .permissionDenied),
    (404, .notFound),
    (429, .rateLimited),
    (400, .providerError),
    (409, .providerError),
    (412, .providerError),
    (500, .providerError),
    (503, .providerError)
  ]
  for (status, expected) in httpCases {
    await findingExpectMappedError(
      response: GatewayHTTPResponse(statusCode: status, body: Data("not-json".utf8)),
      expected: expected
    )
  }

  let googleCases: [(String, GatewayErrorCode)] = [
    ("UNAUTHENTICATED", .authenticationFailed),
    ("PERMISSION_DENIED", .permissionDenied),
    ("NOT_FOUND", .notFound),
    ("FAILED_PRECONDITION", .failedPrecondition),
    ("RESOURCE_EXHAUSTED", .rateLimited),
    ("UNKNOWN", .providerError)
  ]
  for (status, expected) in googleCases {
    await findingExpectMappedError(
      response: findingResponse(
        "{\"error\":{\"code\":418,\"message\":\"mapped\",\"status\":\"\(status)\"}}",
        status: 418
      ),
      expected: expected
    )
  }
}

@Test func redactionPreservesPostScrubKeyCollisionsDeterministically() throws {
  let token = "active-token"
  let input: JSONValue = .object([
    "outer": .object([
      "key-<redacted>": .string("already-safe"),
      "key-active-token": .string("contains active-token"),
      "key-<redacted>#2": .string("existing-suffix")
    ])
  ])
  let first = Redactor.redact(input, token: token)
  let second = Redactor.redact(input, token: token)
  #expect(first == second)

  let encoded = String(decoding: try GatewayJSONCodec.encode(first), as: UTF8.self)
  #expect(!encoded.contains(token))
  guard case .object(let root) = first,
        case .object(let nested)? = root["outer"] else {
    Issue.record("Expected nested redacted object")
    return
  }
  #expect(nested.count == 3)
  #expect(nested.values.contains(.string("already-safe")))
  #expect(nested.values.contains(.string("<redacted>")))
  #expect(nested.values.contains(.string("existing-suffix")))
}

@Test func everyCLISuccessCommandUsesItsStableEnvelopeWithoutNetwork() async throws {
  let environment = [
    "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": "token",
    "GOOGLE_SERVICE_GATEWAY_PROJECT": "123"
  ]
  let readerCases: [([String], String, String)] = [
    (["services", "list"], "services.list", "{\"services\":[]}"),
    (["services", "get", "--service", "gmail"], "services.get", "{\"name\":\"projects/123/services/gmail.googleapis.com\"}"),
    (["operations", "get", "--operation", "operations/read"], "operations.get", "{\"name\":\"operations/read\",\"done\":false}")
  ]
  for (arguments, command, body) in readerCases {
    let execution = await ReaderAdapter(
      transport: FindingTransport(responses: [findingResponse(body)])
    ).run(arguments: arguments, environment: environment)
    try findingExpectSuccessEnvelope(execution.output, command: command)
    #expect(execution.exitStatus == 0 && !execution.isError)
  }

  let writerCases: [([String], String)] = [
    (["services", "enable", "--service", "gmail", "--no-wait"], "services.enable"),
    (["services", "disable", "--service", "gmail", "--no-wait"], "services.disable"),
    (["services", "batch-enable", "--service", "gmail", "--service", "drive", "--no-wait"], "services.batch-enable")
  ]
  for (index, entry) in writerCases.enumerated() {
    let execution = await WriterAdapter(
      transport: FindingTransport(responses: [findingResponse(
        "{\"name\":\"operations/write-\(index)\",\"done\":false}"
      )])
    ).run(arguments: entry.0, environment: environment)
    try findingExpectSuccessEnvelope(execution.output, command: entry.1)
    #expect(execution.exitStatus == 0 && !execution.isError)
  }
}

private actor FindingTransport: GatewayHTTPTransport {
  private var responses: [GatewayHTTPResponse]
  private var recorded: [GatewayHTTPRequest] = []

  init(responses: [GatewayHTTPResponse]) { self.responses = responses }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !responses.isEmpty else {
      throw GatewayError(.unexpectedError, "missing finding response")
    }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private func findingClient(
  _ transport: FindingTransport,
  token: String = "token"
) -> GoogleServiceGatewayClient {
  GoogleServiceGatewayClient(
    transport: transport,
    tokenProvider: StaticAccessTokenProvider(token: token)
  )
}

private func findingResponse(
  _ body: String,
  status: Int = 200
) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: Data(body.utf8))
}

private func findingQueryValue(
  _ name: String,
  in request: GatewayHTTPRequest
) -> String? {
  URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
    .queryItems?
    .first(where: { $0.name == name })?
    .value
}

private func findingDecodedBody(_ request: GatewayHTTPRequest) throws -> JSONValue {
  try GatewayJSONCodec.decode(try #require(request.body))
}

private func findingExpectMappedError(
  response: GatewayHTTPResponse,
  expected: GatewayErrorCode
) async {
  let client = findingClient(FindingTransport(responses: [response]))
  do {
    _ = try await client.listServices(.init(project: "123"))
    Issue.record("Expected mapped provider error")
  } catch let error as GatewayError {
    #expect(error.code == expected)
    #expect(error.httpStatus == response.statusCode)
  } catch {
    Issue.record("Unexpected mapped error type")
  }
}

private func findingExpectSuccessEnvelope(
  _ output: String,
  command: String
) throws {
  guard case .object(let envelope) = try GatewayJSONCodec.decode(Data(output.utf8)) else {
    Issue.record("Expected success envelope object")
    return
  }
  #expect(envelope["ok"] == .bool(true))
  #expect(envelope["command"] == .string(command))
  #expect(envelope["data"] != nil)
  #expect(envelope["error"] == nil)
}
