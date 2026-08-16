import Foundation

public struct GoogleProjectProvisioningClient: Sendable {
  private let transport: any GatewayHTTPTransport
  private let tokenProvider: any AccessTokenProvider
  private let sleeper: any GatewaySleeper
  private let clock: any GatewayClock
  private let resourceManagerBaseURL: URL
  private let serviceUsageBaseURL: URL

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    tokenProvider: any AccessTokenProvider,
    resourceManagerBaseURL: URL = URL(string: "https://cloudresourcemanager.googleapis.com")!,
    serviceUsageBaseURL: URL = URL(string: "https://serviceusage.googleapis.com")!,
    sleeper: any GatewaySleeper = TaskGatewaySleeper(),
    clock: any GatewayClock = SystemGatewayClock()
  ) {
    self.transport = transport
    self.tokenProvider = tokenProvider
    self.resourceManagerBaseURL = resourceManagerBaseURL
    self.serviceUsageBaseURL = serviceUsageBaseURL
    self.sleeper = sleeper
    self.clock = clock
  }

  public func create(_ request: CreateProjectRequest) async throws -> ProjectProvisioningResult {
    let projectID = try GatewayValidation.projectID(request.projectID)
    let displayName = try GatewayValidation.projectDisplayName(request.displayName)
    let parent = try request.parent.map(GatewayValidation.projectParent)
    let labels = try GatewayValidation.projectLabels(request.labels)
    guard request.billingAccount == nil else {
      throw GatewayError(
        .invalidArgument,
        "billing attachment is restricted to google-service-gateway-admin"
      )
    }
    let services = try request.services.isEmpty ? [] : GatewayValidation.batchServices(request.services)
    let scopes = try GoogleOAuthScopeCatalog.resolve(request.oauthScopes)
    try GatewayValidation.polling(request.options)
    guard request.options.wait || services.isEmpty else {
      throw GatewayError(
        .invalidArgument,
        "--no-wait cannot be combined with billing attachment or service enablement"
      )
    }

    var body: [String: JSONValue] = [
      "projectId": .string(projectID),
      "displayName": .string(displayName)
    ]
    if let parent { body["parent"] = .string(parent) }
    if !labels.isEmpty { body["labels"] = .object(labels.mapValues(JSONValue.string)) }

    let scrubber = ProjectMutationScrubber()
    var operation = try projectOperation(
      try await send(
        method: "POST",
        baseURL: resourceManagerBaseURL,
        path: "/v3/projects",
        body: .object(body),
        scrubber: scrubber
      )
    )
    if operation.done {
      operation = try completed(operation, scrubber: scrubber)
    } else if request.options.wait {
      operation = try await waitForProjectOperation(
        operation, options: request.options, scrubber: scrubber)
    }

    let project = try operation.response.map { try gatewayProject($0, expectedID: projectID) }
    let serviceEnablement: MutationResult?
    if services.isEmpty {
      serviceEnablement = nil
    } else {
      let serviceClient = GoogleServiceGatewayClient(
        transport: transport,
        tokenProvider: tokenProvider,
        baseURL: serviceUsageBaseURL,
        sleeper: sleeper,
        clock: clock
      )
      serviceEnablement = try await serviceClient.batchEnable(
        project: projectID,
        services: services,
        options: request.options
      )
    }
    return ProjectProvisioningResult(
      projectID: projectID,
      project: project,
      createOperation: operation,
      billing: nil,
      serviceEnablement: serviceEnablement,
      oauthClientSetup: try GoogleAuthPlatformSetup.client(project: projectID),
      oauthConsentSetup: try GoogleAuthPlatformSetup.consent(
        project: projectID, scopes: scopes)
    )
  }

  public func delete(
    project inputProject: String,
    options: MutationOptions = MutationOptions()
  ) async throws -> ProjectLifecycleResult {
    try await projectLifecycleMutation(
      project: inputProject,
      method: "DELETE",
      suffix: "",
      body: nil,
      action: .delete,
      options: options
    )
  }

  public func undelete(
    project inputProject: String,
    options: MutationOptions = MutationOptions()
  ) async throws -> ProjectLifecycleResult {
    try await projectLifecycleMutation(
      project: inputProject,
      method: "POST",
      suffix: ":undelete",
      body: .object([:]),
      action: .undelete,
      options: options
    )
  }

  private func projectLifecycleMutation(
    project inputProject: String,
    method: String,
    suffix: String,
    body: JSONValue?,
    action: ProjectLifecycleAction,
    options: MutationOptions
  ) async throws -> ProjectLifecycleResult {
    let project = try GatewayValidation.project(inputProject)
    try GatewayValidation.polling(options)
    let scrubber = ProjectMutationScrubber()
    var operation = try projectOperation(
      try await send(
        method: method,
        baseURL: resourceManagerBaseURL,
        path: "/v3/\(project)\(suffix)",
        body: body,
        scrubber: scrubber
      )
    )
    if operation.done {
      operation = try completed(operation, scrubber: scrubber)
    } else if options.wait {
      operation = try await waitForProjectOperation(
        operation, options: options, scrubber: scrubber)
    }
    return ProjectLifecycleResult(
      project: project,
      action: action,
      waited: options.wait,
      operation: operation
    )
  }

  private func waitForProjectOperation(
    _ initial: GatewayOperation,
    options: MutationOptions,
    scrubber: ProjectMutationScrubber
  ) async throws -> GatewayOperation {
    var operation = initial
    if operation.done { return try completed(operation, scrubber: scrubber) }
    let deadline = clock.now() + options.timeout
    while true {
      do {
        try Task.checkCancellation()
        let remaining = deadline - clock.now()
        guard remaining > 0 else { throw projectTimeout(operation, scrubber: scrubber) }
        try await sleeper.sleep(for: min(options.pollInterval, remaining))
        guard clock.now() < deadline else { throw projectTimeout(operation, scrubber: scrubber) }
        let expectedName = operation.name
        let suffix = String(operation.name.dropFirst("operations/".count))
        let response = try projectOperation(
          try await send(
            baseURL: resourceManagerBaseURL,
            path: "/v3/operations/\(GatewayValidation.percentEncodePathSegment(suffix))",
            percentEncoded: true,
            scrubber: scrubber
          )
        )
        guard response.name == expectedName else {
          throw GatewayError(.malformedResponse, "operation response name does not match request")
        }
        operation = response
        if operation.done { return try completed(operation, scrubber: scrubber) }
      } catch is CancellationError {
        throw GatewayError(
          .cancelled,
          "operation cancelled",
          operationName: scrubber.scrub(operation.name)
        )
      }
    }
  }

  private func completed(
    _ operation: GatewayOperation,
    scrubber: ProjectMutationScrubber
  ) throws -> GatewayOperation {
    if let error = operation.error {
      throw GatewayError(
        .operationFailed,
        scrubber.scrub(error.message),
        googleCode: error.code,
        operationName: scrubber.scrub(operation.name),
        details: error.details?.map(scrubber.redact)
      )
    }
    guard operation.response != nil else {
      throw GatewayError(.malformedResponse, "project operation has no response")
    }
    return operation
  }

  private func projectTimeout(
    _ operation: GatewayOperation,
    scrubber: ProjectMutationScrubber
  ) -> GatewayError {
    GatewayError(
      .operationTimeout,
      "operation polling timed out",
      operationName: scrubber.scrub(operation.name)
    )
  }

  private func send(
    method: String = "GET",
    baseURL: URL,
    path: String,
    body: JSONValue? = nil,
    percentEncoded: Bool = false,
    scrubber: ProjectMutationScrubber
  ) async throws -> JSONValue {
    let token = try await tokenProvider.accessToken()
    scrubber.record(token)
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    if percentEncoded { components?.percentEncodedPath = path } else { components?.path = path }
    guard let url = components?.url else {
      throw GatewayError(.unexpectedError, "could not construct provider URL")
    }
    let data = try body.map { try GatewayJSONCodec.encode($0) }
    var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    if data != nil { headers["Content-Type"] = "application/json" }
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(
        .init(method: method, url: url, headers: headers, body: data))
    } catch is CancellationError {
      throw GatewayError(.cancelled, "operation cancelled")
    } catch let error as GatewayError {
      throw Redactor.redact(error, token: token)
    } catch {
      throw GatewayError(.providerError, "transport request failed")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw projectProviderError(response, token: token)
    }
    do { return try GatewayJSONCodec.decode(response.body) } catch {
      throw GatewayError(
        .malformedResponse,
        "provider response could not be decoded",
        httpStatus: response.statusCode
      )
    }
  }
}

private final class ProjectMutationScrubber: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String] = []

  func record(_ token: String) {
    guard !token.isEmpty else { return }
    lock.withLock {
      if !tokens.contains(token) { tokens.append(token) }
    }
  }

  func scrub(_ value: String) -> String {
    lock.withLock { tokens.reduce(value) { Redactor.scrub($0, token: $1) } }
  }

  func redact(_ value: JSONValue) -> JSONValue {
    lock.withLock { tokens.reduce(value) { Redactor.redact($0, token: $1) } }
  }

  deinit { tokens.removeAll(keepingCapacity: false) }
}

private func projectOperation(_ value: JSONValue) throws -> GatewayOperation {
  let object = try projectObject(value)
  let name = try GatewayValidation.operation(try projectRequiredString(object, "name"))
  let done = try projectOptionalBool(object["done"]) ?? false
  let response = try projectOptionalObject(object["response"])
  let error: GatewayOperationError?
  if let value = object["error"] {
    let errorObject = try projectObject(value)
    error = GatewayOperationError(
      code: try projectRequiredInt(errorObject, "code"),
      message: try projectRequiredString(errorObject, "message"),
      details: try projectOptionalArray(errorObject["details"])
    )
  } else {
    error = nil
  }
  guard !(!done && (response != nil || error != nil)), !(response != nil && error != nil) else {
    throw GatewayError(.malformedResponse, "invalid operation result union")
  }
  return GatewayOperation(
    name: name,
    done: done,
    metadata: try projectOptionalObject(object["metadata"]),
    response: response,
    error: error
  )
}

private func gatewayProject(_ value: JSONValue, expectedID: String) throws -> GatewayProject {
  let object = try projectObject(value)
  let projectID = try projectRequiredString(object, "projectId")
  guard projectID == expectedID else {
    throw GatewayError(.malformedResponse, "project response does not match request")
  }
  let resourceName = try projectRequiredString(object, "name")
  _ = try GatewayValidation.project(resourceName)
  let state = try projectRequiredString(object, "state")
  guard state == "ACTIVE" else {
    throw GatewayError(.malformedResponse, "created project is not active")
  }
  let labelsObject = try projectOptionalObject(object["labels"])
  var labels: [String: String] = [:]
  if case .object(let rawLabels) = labelsObject {
    for (key, value) in rawLabels {
      guard case .string(let string) = value else {
        throw GatewayError(.malformedResponse, "provider response could not be decoded")
      }
      labels[key] = string
    }
  }
  return GatewayProject(
    resourceName: resourceName,
    projectID: projectID,
    displayName: try projectRequiredString(object, "displayName"),
    parent: try projectOptionalString(object["parent"]),
    state: state,
    labels: labels,
    createTime: try projectOptionalString(object["createTime"])
  )
}

private func projectProviderError(_ response: GatewayHTTPResponse, token: String) -> GatewayError {
  let value = try? GatewayJSONCodec.decode(response.body)
  let outer = try? value.map(projectObject)
  let errorObject = try? outer.flatMap { object in
    try object["error"].map(projectObject) ?? object
  }
  let message = Redactor.scrub(
    (try? projectOptionalString(errorObject?["message"])) ?? "provider request failed",
    token: token
  )
  let status = try? projectOptionalString(errorObject?["status"])
  let googleCode = try? projectOptionalInt(errorObject?["code"])
  let details = (try? projectOptionalArray(errorObject?["details"]))?.map {
    Redactor.redact($0, token: token)
  }
  let code: GatewayErrorCode = switch status {
  case "UNAUTHENTICATED": .authenticationFailed
  case "PERMISSION_DENIED": .permissionDenied
  case "NOT_FOUND": .notFound
  case "FAILED_PRECONDITION": .failedPrecondition
  case "RESOURCE_EXHAUSTED": .rateLimited
  default:
    switch response.statusCode {
    case 401: .authenticationFailed
    case 403: .permissionDenied
    case 404: .notFound
    case 429: .rateLimited
    default: .providerError
    }
  }
  return GatewayError(
    code,
    message,
    httpStatus: response.statusCode,
    googleCode: googleCode,
    googleStatus: status,
    details: details
  )
}

private func projectObject(_ value: JSONValue) throws -> [String: JSONValue] {
  guard case .object(let object) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return object
}

private func projectOptionalObject(_ value: JSONValue?) throws -> JSONValue? {
  guard let value else { return nil }
  guard case .object = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return value
}

private func projectRequiredString(_ object: [String: JSONValue], _ key: String) throws -> String {
  guard let value = try projectOptionalString(object[key]) else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return value
}

private func projectOptionalString(_ value: JSONValue?) throws -> String? {
  guard let value else { return nil }
  guard case .string(let string) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return string
}

private func projectRequiredInt(_ object: [String: JSONValue], _ key: String) throws -> Int {
  guard let value = try projectOptionalInt(object[key]) else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return value
}

private func projectOptionalInt(_ value: JSONValue?) throws -> Int? {
  guard let value else { return nil }
  guard case .number(let raw) = value, let number = Int(raw) else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return number
}

private func projectRequiredBool(_ object: [String: JSONValue], _ key: String) throws -> Bool {
  guard let value = try projectOptionalBool(object[key]) else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return value
}

private func projectOptionalBool(_ value: JSONValue?) throws -> Bool? {
  guard let value else { return nil }
  guard case .bool(let bool) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return bool
}

private func projectOptionalArray(_ value: JSONValue?) throws -> [JSONValue]? {
  guard let value else { return nil }
  guard case .array(let array) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return array
}
