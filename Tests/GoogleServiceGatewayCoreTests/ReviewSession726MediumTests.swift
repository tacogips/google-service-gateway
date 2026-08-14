import Foundation
import Testing
@testable import GoogleServiceGatewayCore

@Test func providerErrorRedactsNextPageTokenDetail() async throws {
  let secret = "provider-error-page-token"
  let response = mediumResponse(
    """
    {"error":{"code":400,"message":"bad page","status":"INVALID_ARGUMENT","details":[{"nextPageToken":"\(secret)"}]}}
    """,
    status: 400
  )
  let client = mediumClient(transport: MediumTransport(responses: [response]))

  do {
    _ = try await client.listServices(.init(project: "123"))
    Issue.record("Expected provider error")
  } catch let error as GatewayError {
    #expect(error.code == .providerError)
    #expect(error.details == [.object(["nextPageToken": .string("<redacted>")])])
    let encoded = String(decoding: try GatewayJSONCodec.encode(error), as: UTF8.self)
    #expect(!encoded.contains(secret))
  } catch {
    Issue.record("Unexpected provider error type")
  }
}

@Test func pollingRejectsSubstitutedOperationNameWithoutFollowingIt() async throws {
  let transport = MediumTransport(responses: [
    mediumResponse("{\"name\":\"operations/requested\",\"done\":false}"),
    mediumResponse("{\"name\":\"operations/substituted\",\"done\":false}"),
    mediumResponse("{\"name\":\"operations/substituted\",\"done\":true,\"response\":{}}")
  ])
  let client = mediumClient(transport: transport)

  do {
    _ = try await client.enable(
      project: "123",
      service: "gmail",
      options: .init(wait: true, pollInterval: 1, timeout: 10)
    )
    Issue.record("Expected substituted operation name rejection")
  } catch let error as GatewayError {
    #expect(error.code == .malformedResponse)
  } catch {
    Issue.record("Unexpected operation mismatch error type")
  }

  let requests = await transport.requests()
  #expect(requests.count == 2)
  #expect(requests.last?.url.path == "/v1/operations/requested")
}

@Test func rotatingTokensAreScrubbedFromOperationFailure() async throws {
  let tokens = ["rotation-token-one", "rotation-token-two"]
  let name = "operations/\(tokens.joined(separator: "."))"
  let client = rotatingMediumClient(
    responses: [
      mediumResponse("{\"name\":\"\(name)\",\"done\":false}"),
      mediumResponse("{\"name\":\"\(name)\",\"done\":true,\"error\":{\"code\":7,\"message\":\"denied\"}}")
    ],
    tokens: tokens
  )

  await expectScrubbedMutationError(client: client, code: .operationFailed, tokens: tokens)
}

@Test func rotatingTokensAreScrubbedFromOperationTimeout() async throws {
  let tokens = ["timeout-token-one", "timeout-token-two"]
  let name = "operations/\(tokens.joined(separator: "."))"
  let client = rotatingMediumClient(
    responses: [
      mediumResponse("{\"name\":\"\(name)\",\"done\":false}"),
      mediumResponse("{\"name\":\"\(name)\",\"done\":false}")
    ],
    tokens: tokens,
    clock: MediumSequenceClock(values: [0, 0, 0, 1])
  )

  await expectScrubbedMutationError(
    client: client,
    code: .operationTimeout,
    tokens: tokens,
    options: .init(wait: true, pollInterval: 0.1, timeout: 1)
  )
}

@Test func rotatingTokensAreScrubbedFromOperationCancellation() async throws {
  let tokens = ["cancel-token-one", "cancel-token-two"]
  let name = "operations/\(tokens.joined(separator: "."))"
  let client = rotatingMediumClient(
    responses: [
      mediumResponse("{\"name\":\"\(name)\",\"done\":false}"),
      mediumResponse("{\"name\":\"\(name)\",\"done\":false}")
    ],
    tokens: tokens,
    sleeper: CancelAfterFirstMediumSleep()
  )

  await expectScrubbedMutationError(client: client, code: .cancelled, tokens: tokens)
}

@Test func rotatingTokensDoNotModifySuccessfulOperationOutput() async throws {
  let tokens = ["success-token-one", "success-token-two"]
  let name = "operations/\(tokens.joined(separator: "."))"
  let client = rotatingMediumClient(
    responses: [
      mediumResponse("{\"name\":\"\(name)\",\"done\":false}"),
      mediumResponse("{\"name\":\"\(name)\",\"done\":true,\"response\":{\"opaque\":\"\(tokens[0])\"}}")
    ],
    tokens: tokens
  )

  let result = try await client.enable(
    project: "123",
    service: "gmail",
    options: .init(wait: true, pollInterval: 1, timeout: 10)
  )
  #expect(result.operation.name == name)
  #expect(result.operation.response == .object(["opaque": .string(tokens[0])]))
}

private actor MediumTransport: GatewayHTTPTransport {
  private var responses: [GatewayHTTPResponse]
  private var recorded: [GatewayHTTPRequest] = []

  init(responses: [GatewayHTTPResponse]) {
    self.responses = responses
  }

  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    recorded.append(request)
    guard !responses.isEmpty else {
      throw GatewayError(.unexpectedError, "missing medium-finding response")
    }
    return responses.removeFirst()
  }

  func requests() -> [GatewayHTTPRequest] { recorded }
}

private actor RotatingMediumTokenProvider: AccessTokenProvider {
  private var tokens: [String]

  init(tokens: [String]) {
    self.tokens = tokens
  }

  func accessToken() async throws -> String {
    guard !tokens.isEmpty else {
      throw GatewayError(.authRequired, "missing rotating test token")
    }
    return tokens.removeFirst()
  }
}

private struct ImmediateMediumSleeper: GatewaySleeper {
  func sleep(for seconds: TimeInterval) async throws {}
}

private actor CancelAfterFirstMediumSleep: GatewaySleeper {
  private var count = 0

  func sleep(for seconds: TimeInterval) async throws {
    count += 1
    if count == 2 { throw CancellationError() }
  }
}

private struct ConstantMediumClock: GatewayClock {
  func now() -> TimeInterval { 0 }
}

private final class MediumSequenceClock: GatewayClock, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [TimeInterval]

  init(values: [TimeInterval]) {
    self.values = values
  }

  func now() -> TimeInterval {
    lock.withLock {
      guard values.count > 1 else { return values.first ?? 0 }
      return values.removeFirst()
    }
  }
}

private func mediumClient(
  transport: MediumTransport,
  tokenProvider: any AccessTokenProvider = StaticAccessTokenProvider(token: "token"),
  sleeper: any GatewaySleeper = ImmediateMediumSleeper(),
  clock: any GatewayClock = ConstantMediumClock()
) -> GoogleServiceGatewayClient {
  GoogleServiceGatewayClient(
    transport: transport,
    tokenProvider: tokenProvider,
    sleeper: sleeper,
    clock: clock
  )
}

private func rotatingMediumClient(
  responses: [GatewayHTTPResponse],
  tokens: [String],
  sleeper: any GatewaySleeper = ImmediateMediumSleeper(),
  clock: any GatewayClock = ConstantMediumClock()
) -> GoogleServiceGatewayClient {
  mediumClient(
    transport: MediumTransport(responses: responses),
    tokenProvider: RotatingMediumTokenProvider(tokens: tokens),
    sleeper: sleeper,
    clock: clock
  )
}

private func expectScrubbedMutationError(
  client: GoogleServiceGatewayClient,
  code: GatewayErrorCode,
  tokens: [String],
  options: MutationOptions = .init(wait: true, pollInterval: 1, timeout: 10)
) async {
  do {
    _ = try await client.enable(project: "123", service: "gmail", options: options)
    Issue.record("Expected \(code.rawValue)")
  } catch let error as GatewayError {
    #expect(error.code == code)
    let operationName = error.operationName ?? ""
    for token in tokens { #expect(!operationName.contains(token)) }
    #expect(operationName.contains("<redacted>"))
  } catch {
    Issue.record("Unexpected rotating-token error type")
  }
}

private func mediumResponse(
  _ body: String,
  status: Int = 200
) -> GatewayHTTPResponse {
  GatewayHTTPResponse(statusCode: status, body: Data(body.utf8))
}
