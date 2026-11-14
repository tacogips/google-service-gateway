import Foundation

public struct GoogleAPIKeysClient: Sendable {
  private let transport: any GatewayHTTPTransport
  private let tokenProvider: any AccessTokenProvider
  private let sleeper: any GatewaySleeper
  private let clock: any GatewayClock
  private let baseURL: URL

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    tokenProvider: any AccessTokenProvider,
    baseURL: URL = URL(string: "https://apikeys.googleapis.com")!,
    sleeper: any GatewaySleeper = TaskGatewaySleeper(),
    clock: any GatewayClock = SystemGatewayClock()
  ) {
    self.transport = transport
    self.tokenProvider = tokenProvider
    self.baseURL = baseURL
    self.sleeper = sleeper
    self.clock = clock
  }

  public func list(project inputProject: String, pageSize: Int = 50, pageToken: String? = nil)
    async throws -> APIKeyListResult
  {
    let project = try GatewayValidation.project(inputProject)
    let validatedSize = try GatewayValidation.pageSize(pageSize)
    let validatedToken = try GatewayValidation.pageToken(pageToken)
    var query = [URLQueryItem(name: "pageSize", value: String(validatedSize))]
    if let validatedToken { query.append(URLQueryItem(name: "pageToken", value: validatedToken)) }
    let value = try await send(path: "/v2/\(project)/locations/global/keys", query: query)
    let object = try apiObject(value)
    let keys = try apiArray(object["keys"]).map(apiKeyResource)
    return APIKeyListResult(
      project: project, keys: keys, nextPageToken: try apiOptionalString(object["nextPageToken"]))
  }

  public func get(_ inputName: String) async throws -> APIKeyGetResult {
    let name = try GatewayValidation.apiKeyResource(inputName)
    return APIKeyGetResult(key: try apiKeyResource(sendValue(try await send(path: "/v2/\(name)"))))
  }

  public func getKeyString(_ inputName: String) async throws -> APIKeyStringResult {
    let name = try GatewayValidation.apiKeyResource(inputName)
    let object = try apiObject(sendValue(try await send(path: "/v2/\(name)/keyString")))
    return APIKeyStringResult(name: name, keyString: try apiRequiredString(object, "keyString"))
  }

  public func create(_ request: CreateAPIKeyRequest) async throws -> APIKeyMutationResult {
    let project = try GatewayValidation.project(request.project)
    let name = try GatewayValidation.displayName(request.displayName)
    let restrictions = try GatewayValidation.apiKeyRestrictions(request.restrictions)
    try GatewayValidation.polling(request.options)
    var query: [URLQueryItem] = []
    if let keyID = request.keyID {
      query.append(URLQueryItem(name: "keyId", value: try GatewayValidation.apiKeyID(keyID)))
    }
    let body: JSONValue = .object([
      "displayName": .string(name), "restrictions": restrictions.gatewayJSONValue(),
    ])
    let scrubber = APIKeyMutationScrubber()
    return try await mutation(
      initial: sendValue(
        try await send(
          method: "POST", path: "/v2/\(project)/locations/global/keys", query: query, body: body,
          mutationScrubber: scrubber)),
      options: request.options,
      scrubber: scrubber
    )
  }

  public func restrict(
    _ inputName: String,
    displayName: String? = nil,
    restrictions inputRestrictions: APIKeyRestrictions,
    options: MutationOptions = MutationOptions()
  ) async throws -> APIKeyMutationResult {
    let name = try GatewayValidation.apiKeyResource(inputName)
    let restrictions = try GatewayValidation.apiKeyRestrictions(inputRestrictions)
    try GatewayValidation.polling(options)
    var body: [String: JSONValue] = [
      "name": .string(name), "restrictions": restrictions.gatewayJSONValue(),
    ]
    var mask = ["restrictions"]
    if let displayName {
      body["displayName"] = .string(try GatewayValidation.displayName(displayName))
      mask.append("display_name")
    }
    let scrubber = APIKeyMutationScrubber()
    return try await mutation(
      initial: sendValue(
        try await send(
          method: "PATCH",
          path: "/v2/\(name)",
          query: [URLQueryItem(name: "updateMask", value: mask.joined(separator: ","))],
          body: .object(body),
          mutationScrubber: scrubber
        )),
      options: options,
      scrubber: scrubber
    )
  }

  public func delete(_ inputName: String, options: MutationOptions = MutationOptions()) async throws
    -> APIKeyMutationResult
  {
    try await namedMutation(method: "DELETE", name: inputName, suffix: "", options: options)
  }

  public func undelete(_ inputName: String, options: MutationOptions = MutationOptions())
    async throws -> APIKeyMutationResult
  {
    try await namedMutation(
      method: "POST", name: inputName, suffix: ":undelete", body: .object([:]), options: options)
  }

  private func namedMutation(
    method: String,
    name inputName: String,
    suffix: String,
    body: JSONValue? = nil,
    options: MutationOptions
  ) async throws -> APIKeyMutationResult {
    let name = try GatewayValidation.apiKeyResource(inputName)
    try GatewayValidation.polling(options)
    let scrubber = APIKeyMutationScrubber()
    return try await mutation(
      initial: sendValue(
        try await send(
          method: method, path: "/v2/\(name)\(suffix)", body: body, mutationScrubber: scrubber)),
      options: options,
      scrubber: scrubber
    )
  }

  private func mutation(
    initial: JSONValue, options: MutationOptions, scrubber: APIKeyMutationScrubber
  ) async throws -> APIKeyMutationResult {
    var operation = try apiOperation(initial)
    guard options.wait else { return APIKeyMutationResult(operation: operation, waited: false) }
    let deadline = clock.now() + options.timeout
    while !operation.done {
      let remaining = deadline - clock.now()
      guard remaining > 0 else {
        throw GatewayError(
          .operationTimeout, "operation polling timed out",
          operationName: scrubber.scrub(operation.name))
      }
      do {
        try await sleeper.sleep(for: min(options.pollInterval, remaining))
      } catch is CancellationError {
        throw GatewayError(
          .cancelled, "operation cancelled", operationName: scrubber.scrub(operation.name))
      }
      guard clock.now() < deadline else {
        throw GatewayError(
          .operationTimeout, "operation polling timed out",
          operationName: scrubber.scrub(operation.name))
      }
      let suffix = String(operation.name.dropFirst("operations/".count))
      operation = try apiOperation(
        sendValue(
          try await send(
            path: "/v2/operations/\(GatewayValidation.percentEncodePathSegment(suffix))",
            percentEncoded: true,
            mutationScrubber: scrubber
          )))
    }
    if let error = operation.error {
      throw GatewayError(
        .operationFailed,
        scrubber.scrub(error.message),
        googleCode: error.code,
        operationName: scrubber.scrub(operation.name),
        details: error.details?.map { scrubber.redact($0) }
      )
    }
    return APIKeyMutationResult(operation: operation, waited: true)
  }

  private func send(
    method: String = "GET",
    path: String,
    query: [URLQueryItem] = [],
    body: JSONValue? = nil,
    percentEncoded: Bool = false,
    mutationScrubber: APIKeyMutationScrubber? = nil
  ) async throws -> JSONValue {
    let token = try await tokenProvider.accessToken()
    mutationScrubber?.record(token)
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    if percentEncoded { components?.percentEncodedPath = path } else { components?.path = path }
    if !query.isEmpty { components?.queryItems = query }
    guard let url = components?.url else {
      throw GatewayError(.unexpectedError, "could not construct provider URL")
    }
    var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    let data = try body.map { try GatewayJSONCodec.encode($0) }
    if data != nil { headers["Content-Type"] = "application/json" }
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(
        .init(method: method, url: url, headers: headers, body: data))
    } catch let error as GatewayError {
      throw Redactor.redact(error, token: token)
    } catch {
      throw GatewayError(.providerError, "transport request failed")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw apiProviderError(response, token: token)
    }
    do { return try GatewayJSONCodec.decode(response.body) } catch {
      throw GatewayError(
        .malformedResponse, "provider response could not be decoded",
        httpStatus: response.statusCode)
    }
  }
}

private final class APIKeyMutationScrubber: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func record(_ value: String) {
    guard !value.isEmpty else { return }
    lock.withLock { if !values.contains(value) { values.append(value) } }
  }

  func scrub(_ value: String) -> String {
    lock.withLock { values.reduce(value) { Redactor.scrub($0, token: $1) } }
  }

  func redact(_ value: JSONValue) -> JSONValue {
    lock.withLock { values.reduce(Redactor.redact(value)) { Redactor.redact($0, token: $1) } }
  }
}

private func sendValue(_ value: JSONValue) -> JSONValue { value }

private func apiObject(_ value: JSONValue?) throws -> [String: JSONValue] {
  guard case .object(let object) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return object
}

private func apiArray(_ value: JSONValue?) throws -> [JSONValue] {
  guard let value else { return [] }
  guard case .array(let array) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return array
}

private func apiRequiredString(_ object: [String: JSONValue], _ key: String) throws -> String {
  guard case .string(let value) = object[key], !value.isEmpty else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return value
}

private func apiOptionalString(_ value: JSONValue?) throws -> String? {
  guard let value else { return nil }
  guard case .string(let string) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return string
}

private func apiOptionalObject(_ value: JSONValue?) throws -> [String: JSONValue]? {
  guard let value else { return nil }
  return try apiObject(value)
}

private func apiKeyResource(_ value: JSONValue) throws -> APIKeyResource {
  let object = try apiObject(value)
  let restrictions = try apiOptionalObject(object["restrictions"]).map(apiRestrictions)
  return APIKeyResource(
    name: try GatewayValidation.apiKeyResource(apiRequiredString(object, "name")),
    uid: try apiOptionalString(object["uid"]),
    displayName: try apiOptionalString(object["displayName"]) ?? "",
    createTime: try apiOptionalString(object["createTime"]),
    updateTime: try apiOptionalString(object["updateTime"]),
    deleteTime: try apiOptionalString(object["deleteTime"]),
    etag: try apiOptionalString(object["etag"]),
    restrictions: restrictions
  )
}

private func apiRestrictions(_ object: [String: JSONValue]) throws -> APIKeyRestrictions {
  let targets = try apiArray(object["apiTargets"]).map { value -> APIKeyTarget in
    let target = try apiObject(value)
    return APIKeyTarget(
      service: try apiRequiredString(target, "service"),
      methods: try apiArray(target["methods"]).map { try apiString($0) }
    )
  }
  let client: APIKeyClientRestrictions
  if let nested = try apiOptionalObject(object["browserKeyRestrictions"]) {
    client = .browser(allowedReferrers: try apiArray(nested["allowedReferrers"]).map(apiString))
  } else if let nested = try apiOptionalObject(object["serverKeyRestrictions"]) {
    client = .server(allowedIPs: try apiArray(nested["allowedIps"]).map(apiString))
  } else if let nested = try apiOptionalObject(object["iosKeyRestrictions"]) {
    client = .ios(allowedBundleIDs: try apiArray(nested["allowedBundleIds"]).map(apiString))
  } else if let nested = try apiOptionalObject(object["androidKeyRestrictions"]) {
    client = .android(
      allowedApplications: try apiArray(nested["allowedApplications"]).map { value in
        let app = try apiObject(value)
        return AndroidApplicationRestriction(
          packageName: try apiRequiredString(app, "packageName"),
          sha1Fingerprint: try apiRequiredString(app, "sha1Fingerprint")
        )
      })
  } else {
    client = .none
  }
  return APIKeyRestrictions(apiTargets: targets, client: client)
}

private func apiString(_ value: JSONValue) throws -> String {
  guard case .string(let string) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return string
}

private func apiOperation(_ value: JSONValue) throws -> GatewayOperation {
  let object = try apiObject(value)
  let name = try GatewayValidation.operation(apiRequiredString(object, "name"))
  let done: Bool
  if let value = object["done"] {
    guard case .bool(let parsed) = value else {
      throw GatewayError(.malformedResponse, "provider response could not be decoded")
    }
    done = parsed
  } else {
    done = false
  }
  let error: GatewayOperationError?
  if let errorObject = try apiOptionalObject(object["error"]) {
    let code: Int
    if case .number(let raw) = errorObject["code"], let parsed = Int(raw) {
      code = parsed
    } else {
      code = 0
    }
    error = GatewayOperationError(
      code: code,
      message: try apiOptionalString(errorObject["message"]) ?? "operation failed",
      details: try errorObject["details"].map(apiArray)
    )
  } else {
    error = nil
  }
  return GatewayOperation(
    name: name, done: done, metadata: object["metadata"], response: object["response"], error: error
  )
}

private func apiProviderError(_ response: GatewayHTTPResponse, token: String) -> GatewayError {
  let decoded = try? GatewayJSONCodec.decode(response.body)
  let outer = try? apiObject(decoded)
  let error = try? apiOptionalObject(outer?["error"])
  let message = Redactor.scrub(
    (try? apiOptionalString(error?["message"])) ?? "provider request failed", token: token)
  let status = try? apiOptionalString(error?["status"])
  let code: GatewayErrorCode =
    switch (status ?? nil, response.statusCode) {
    case ("UNAUTHENTICATED", _), (_, 401): .authenticationFailed
    case ("PERMISSION_DENIED", _), (_, 403): .permissionDenied
    case ("NOT_FOUND", _), (_, 404): .notFound
    case ("FAILED_PRECONDITION", _), _: .failedPrecondition
    case ("RESOURCE_EXHAUSTED", _), (_, 429): .rateLimited
    default: .providerError
    }
  return GatewayError(code, message, httpStatus: response.statusCode, googleStatus: status ?? nil)
}
