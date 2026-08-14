import Foundation

public struct GoogleServiceGatewayClient: Sendable {
  private let transport: any GatewayHTTPTransport
  private let tokenProvider: any AccessTokenProvider
  private let sleeper: any GatewaySleeper
  private let clock: any GatewayClock
  private let baseURL: URL

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    tokenProvider: any AccessTokenProvider,
    baseURL: URL = URL(string: "https://serviceusage.googleapis.com")!,
    sleeper: any GatewaySleeper = TaskGatewaySleeper(),
    clock: any GatewayClock = SystemGatewayClock()
  ) {
    self.transport = transport
    self.tokenProvider = tokenProvider
    self.baseURL = baseURL
    self.sleeper = sleeper
    self.clock = clock
  }

  public func listServices(_ request: ListServicesRequest) async throws -> ServiceListResult {
    let project = try GatewayValidation.project(request.project)
    let pageSize = try GatewayValidation.pageSize(request.pageSize)
    let pageToken = try GatewayValidation.pageToken(request.pageToken)
    if request.allPages, pageToken != nil { throw GatewayError(.invalidArgument, "--page-token cannot be combined with --all-pages") }

    var services: [GatewayService] = []
    var pages = 0
    var nextToken = pageToken
    var seen = Set<String>()
    repeat {
      var items = [URLQueryItem(name: "pageSize", value: String(pageSize))]
      if let filter = request.state.providerFilter { items.append(URLQueryItem(name: "filter", value: filter)) }
      if let nextToken { items.append(URLQueryItem(name: "pageToken", value: nextToken)) }
      let json = try await sendJSON(path: "/v1/\(project)/services", queryItems: items)
      let response = try providerList(json.value)
      let pageServices = try response.services.map {
        try toGatewayService($0, expectedProject: project)
      }
      services.append(contentsOf: pageServices)
      pages += 1
      let token = try GatewayValidation.returnedPageToken(response.nextPageToken)
      guard request.allPages else {
        return ServiceListResult(project: project, services: services, pagesFetched: pages, nextPageToken: token)
      }
      if let token, !seen.insert(token).inserted { throw GatewayError(.malformedResponse, "repeated page token") }
      nextToken = token
    } while nextToken != nil
    return ServiceListResult(project: project, services: services, pagesFetched: pages, nextPageToken: nil)
  }

  public func getService(project inputProject: String, service inputService: String) async throws -> ServiceGetResult {
    let project = try GatewayValidation.project(inputProject)
    let service = try GatewayValidation.service(inputService)
    let json = try await sendJSON(path: "/v1/\(project)/services/\(service)")
    let provider = try providerService(json.value)
    return ServiceGetResult(
      project: project,
      service: try toGatewayService(
        provider,
        expectedProject: project,
        expectedService: service
      )
    )
  }

  public func getOperation(_ inputOperation: String) async throws -> OperationGetResult {
    OperationGetResult(operation: try await getOperationResponse(inputOperation).operation)
  }

  private func getOperationResponse(
    _ inputOperation: String,
    mutationTokens: MutationTokenScrubber? = nil,
    requireExactName: Bool = false
  ) async throws -> AuthorizedOperation {
    let operation = try GatewayValidation.operation(inputOperation)
    let suffix = String(operation.dropFirst("operations/".count))
    let json = try await sendJSON(
      path: "/v1/operations/\(GatewayValidation.percentEncodePathSegment(suffix))",
      percentEncoded: true,
      mutationTokens: mutationTokens
    )
    let response = try toGatewayOperation(providerOperation(json.value))
    guard !requireExactName || response.name == operation else {
      throw GatewayError(.malformedResponse, "operation response name does not match request")
    }
    return AuthorizedOperation(operation: response)
  }

  public func enable(project inputProject: String, service inputService: String, options: MutationOptions = MutationOptions()) async throws -> MutationResult {
    let project = try GatewayValidation.project(inputProject)
    let service = try GatewayValidation.service(inputService)
    try GatewayValidation.polling(options)
    let tokens = MutationTokenScrubber()
    let json = try await sendJSON(method: "POST", path: "/v1/\(project)/services/\(service):enable", body: JSONValue.object([:]), mutationTokens: tokens)
    let operation = try providerOperation(json.value)
    return try await mutationResult(project: project, services: [service], options: options, operation: operation, mutationTokens: tokens, disableDependents: nil, checkUsage: nil)
  }

  public func disable(project inputProject: String, service inputService: String, disableDependents: Bool = false, checkUsage: Bool = false, options: MutationOptions = MutationOptions()) async throws -> MutationResult {
    let project = try GatewayValidation.project(inputProject)
    let service = try GatewayValidation.service(inputService)
    try GatewayValidation.polling(options)
    let body: JSONValue = .object([
      "disableDependentServices": .bool(disableDependents),
      "checkIfServiceHasUsage": .string(checkUsage ? "CHECK" : "SKIP")
    ])
    let tokens = MutationTokenScrubber()
    let json = try await sendJSON(method: "POST", path: "/v1/\(project)/services/\(service):disable", body: body, mutationTokens: tokens)
    let operation = try providerOperation(json.value)
    return try await mutationResult(project: project, services: [service], options: options, operation: operation, mutationTokens: tokens, disableDependents: disableDependents, checkUsage: checkUsage ? "CHECK" : "SKIP")
  }

  public func batchEnable(project inputProject: String, services inputServices: [String], options: MutationOptions = MutationOptions()) async throws -> MutationResult {
    let project = try GatewayValidation.project(inputProject)
    let services = try GatewayValidation.batchServices(inputServices)
    try GatewayValidation.polling(options)
    let body: JSONValue = .object(["serviceIds": .array(services.map(JSONValue.string))])
    let tokens = MutationTokenScrubber()
    let json = try await sendJSON(method: "POST", path: "/v1/\(project)/services:batchEnable", body: body, mutationTokens: tokens)
    let operation = try providerOperation(json.value)
    return try await mutationResult(project: project, services: services, options: options, operation: operation, mutationTokens: tokens, disableDependents: nil, checkUsage: nil)
  }

  private func mutationResult(
    project: String,
    services: [String],
    options: MutationOptions,
    operation provider: ProviderOperation,
    mutationTokens: MutationTokenScrubber,
    disableDependents: Bool?,
    checkUsage: String?
  ) async throws -> MutationResult {
    let initial = try toGatewayOperation(provider)
    let operation = try await wait(for: AuthorizedOperation(operation: initial), options: options, mutationTokens: mutationTokens)
    return MutationResult(project: project, requestedServices: services, waited: options.wait, disableDependentServices: disableDependents, checkUsage: checkUsage, operation: operation)
  }

  private func wait(
    for initial: AuthorizedOperation,
    options: MutationOptions,
    mutationTokens: MutationTokenScrubber
  ) async throws -> GatewayOperation {
    var operation = initial
    do {
      if initial.operation.done {
        if initial.operation.error != nil { throw operationError(.operationFailed, "operation failed", response: initial, mutationTokens: mutationTokens) }
        return initial.operation
      }
      guard options.wait else { return initial.operation }
      try Task.checkCancellation()
      let deadline = clock.now() + options.timeout
      while true {
        try Task.checkCancellation()
        let now = clock.now()
        guard now < deadline else { throw operationError(.operationTimeout, "operation polling timed out", response: operation, mutationTokens: mutationTokens) }
        try await sleeper.sleep(for: min(options.pollInterval, deadline - now))
        try Task.checkCancellation()
        guard clock.now() < deadline else { throw operationError(.operationTimeout, "operation polling timed out", response: operation, mutationTokens: mutationTokens) }
        operation = try await getOperationResponse(
          operation.operation.name,
          mutationTokens: mutationTokens,
          requireExactName: true
        )
        if operation.operation.done {
          if operation.operation.error != nil { throw operationError(.operationFailed, "operation failed", response: operation, mutationTokens: mutationTokens) }
          return operation.operation
        }
      }
    } catch is CancellationError {
      throw operationError(.cancelled, "operation cancelled", response: operation, mutationTokens: mutationTokens)
    } catch let error as GatewayError where error.code == .cancelled {
      throw operationError(.cancelled, "operation cancelled", response: operation, mutationTokens: mutationTokens)
    }
  }

  private func operationError(
    _ code: GatewayErrorCode,
    _ message: String,
    response: AuthorizedOperation,
    mutationTokens: MutationTokenScrubber
  ) -> GatewayError {
    GatewayError(code, message, operationName: mutationTokens.scrub(response.operation.name))
  }

  private func sendJSON(method: String = "GET", path: String, queryItems: [URLQueryItem] = [], body: JSONValue? = nil, percentEncoded: Bool = false, mutationTokens: MutationTokenScrubber? = nil) async throws -> ProviderJSONResponse {
    let token = try await tokenProvider.accessToken()
    mutationTokens?.record(token)
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    if percentEncoded { components?.percentEncodedPath = path } else { components?.path = path }
    components?.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components?.url else { throw GatewayError(.invalidArgument, "invalid request URL") }
    let data = try body.map { try GatewayJSONCodec.encode($0) }
    var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    if data != nil { headers["Content-Type"] = "application/json" }
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(GatewayHTTPRequest(method: method, url: url, headers: headers, body: data))
    } catch is CancellationError {
      throw GatewayError(.cancelled, "operation cancelled")
    } catch let error as GatewayError {
      throw Redactor.redact(error, token: token)
    } catch {
      throw GatewayError(.providerError, "transport request failed")
    }
    guard (200..<300).contains(response.statusCode) else { throw providerError(response, token: token) }
    do {
      return ProviderJSONResponse(value: try GatewayJSONCodec.decode(response.body))
    } catch {
      throw GatewayError(.malformedResponse, "provider response could not be decoded", httpStatus: response.statusCode)
    }
  }

  private func providerError(_ response: GatewayHTTPResponse, token: String) -> GatewayError {
    let decoded = try? providerErrorEnvelope(GatewayJSONCodec.decode(response.body))
    let message = Redactor.scrub(decoded?.message ?? "provider request failed", token: token)
    let status = decoded?.status
    let code: GatewayErrorCode
    switch status {
    case "UNAUTHENTICATED": code = .authenticationFailed
    case "PERMISSION_DENIED": code = .permissionDenied
    case "NOT_FOUND": code = .notFound
    case "FAILED_PRECONDITION": code = .failedPrecondition
    case "RESOURCE_EXHAUSTED": code = .rateLimited
    default:
      switch response.statusCode {
      case 401: code = .authenticationFailed
      case 403: code = .permissionDenied
      case 404: code = .notFound
      case 429: code = .rateLimited
      default: code = .providerError
      }
    }
    let details = decoded?.details.map { $0.map { Redactor.redact($0, token: token) } }
    return GatewayError(
      code,
      message,
      httpStatus: response.statusCode,
      googleCode: decoded?.code,
      googleStatus: status.map { Redactor.scrub($0, token: token) },
      details: details
    )
  }
}

private struct ProviderJSONResponse { let value: JSONValue }
private struct AuthorizedOperation { let operation: GatewayOperation }

private final class MutationTokenScrubber: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String] = []

  func record(_ token: String) {
    guard !token.isEmpty else { return }
    lock.withLock {
      if !tokens.contains(token) { tokens.append(token) }
    }
  }

  func scrub(_ value: String) -> String {
    lock.withLock {
      tokens.reduce(value) { Redactor.scrub($0, token: $1) }
    }
  }

  deinit {
    tokens.removeAll(keepingCapacity: false)
  }
}

private struct ProviderList { let services: [ProviderService]; let nextPageToken: String? }
private struct ProviderService { let name: String; let state: ServiceState?; let config: JSONValue? }
private struct ProviderOperation { let name: String; let done: Bool?; let metadata: JSONValue?; let response: JSONValue?; let error: GatewayOperationError? }
private struct ProviderError { let code: Int?; let message: String?; let status: String?; let details: [JSONValue]? }

private func providerList(_ value: JSONValue) throws -> ProviderList {
  let object = try objectValue(value)
  let services = try arrayValue(object["services"] ?? .array([])).map(providerService)
  return ProviderList(services: services, nextPageToken: try optionalString(object["nextPageToken"]))
}

private func providerService(_ value: JSONValue) throws -> ProviderService {
  let object = try objectValue(value)
  let state: ServiceState?
  if let rawState = try optionalString(object["state"]) {
    guard let parsed = ServiceState(rawValue: rawState) else { throw malformedProviderResponse() }
    state = parsed
  } else {
    state = nil
  }
  return ProviderService(name: try requiredString(object, key: "name"), state: state, config: object["config"])
}

private func providerOperation(_ value: JSONValue) throws -> ProviderOperation {
  let object = try objectValue(value)
  let error: GatewayOperationError?
  if let rawError = object["error"] {
    let errorObject = try objectValue(rawError)
    error = GatewayOperationError(
      code: try requiredInt(errorObject, key: "code"),
      message: try requiredString(errorObject, key: "message"),
      details: try optionalArray(errorObject["details"])
    )
  } else {
    error = nil
  }
  return ProviderOperation(
    name: try requiredString(object, key: "name"),
    done: try optionalBool(object["done"]),
    metadata: try optionalObject(object["metadata"]),
    response: try optionalObject(object["response"]),
    error: error
  )
}

private func optionalObject(_ value: JSONValue?) throws -> JSONValue? {
  guard let value else { return nil }
  guard case .object = value else { throw malformedProviderResponse() }
  return value
}

private func providerErrorEnvelope(_ value: JSONValue) throws -> ProviderError {
  let outer = try objectValue(value)
  let object = try objectValue(outer["error"] ?? value)
  return ProviderError(
    code: try optionalInt(object["code"]),
    message: try optionalString(object["message"]),
    status: try optionalString(object["status"]),
    details: try optionalArray(object["details"])
  )
}

private func objectValue(_ value: JSONValue) throws -> [String: JSONValue] {
  guard case .object(let object) = value else { throw malformedProviderResponse() }
  return object
}

private func arrayValue(_ value: JSONValue) throws -> [JSONValue] {
  guard case .array(let array) = value else { throw malformedProviderResponse() }
  return array
}

private func optionalArray(_ value: JSONValue?) throws -> [JSONValue]? {
  guard let value else { return nil }
  return try arrayValue(value)
}

private func requiredString(_ object: [String: JSONValue], key: String) throws -> String {
  guard let value = try optionalString(object[key]) else { throw malformedProviderResponse() }
  return value
}

private func optionalString(_ value: JSONValue?) throws -> String? {
  guard let value else { return nil }
  guard case .string(let string) = value else { throw malformedProviderResponse() }
  return string
}

private func requiredInt(_ object: [String: JSONValue], key: String) throws -> Int {
  guard let value = try optionalInt(object[key]) else { throw malformedProviderResponse() }
  return value
}

private func optionalInt(_ value: JSONValue?) throws -> Int? {
  guard let value else { return nil }
  guard case .number(let number) = value, let integer = Int(number) else { throw malformedProviderResponse() }
  return integer
}

private func optionalBool(_ value: JSONValue?) throws -> Bool? {
  guard let value else { return nil }
  guard case .bool(let bool) = value else { throw malformedProviderResponse() }
  return bool
}

private func malformedProviderResponse() -> GatewayError {
  GatewayError(.malformedResponse, "provider response could not be decoded")
}

private func toGatewayService(
  _ value: ProviderService,
  expectedProject: String,
  expectedService: String? = nil
) throws -> GatewayService {
  let pieces = value.name.split(separator: "/")
  guard pieces.count == 4, pieces[0] == "projects", pieces[2] == "services" else { throw GatewayError(.malformedResponse, "invalid service response name") }
  let parent = "projects/\(pieces[1])"
  let service = try GatewayValidation.service(String(pieces[3]))
  guard parent == expectedProject, expectedService.map({ $0 == service }) ?? true else {
    throw GatewayError(.malformedResponse, "service response name does not match request")
  }
  let config = value.config ?? .object([:])
  guard case .object = config else { throw GatewayError(.malformedResponse, "invalid service config") }
  return GatewayService(name: value.name, parent: parent, serviceId: service, state: value.state ?? .unspecified, config: config)
}

private func toGatewayOperation(_ value: ProviderOperation) throws -> GatewayOperation {
  let name = try GatewayValidation.operation(value.name)
  let done = value.done ?? false
  if (!done && (value.response != nil || value.error != nil)) ||
    (value.response != nil && value.error != nil) {
    throw GatewayError(.malformedResponse, "invalid operation result union")
  }
  return GatewayOperation(name: name, done: done, metadata: value.metadata, response: done ? value.response : nil, error: done ? value.error : nil)
}
