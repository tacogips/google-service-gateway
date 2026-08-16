import Foundation

public struct ProjectPermissionTestResult: Equatable, Sendable, GatewayJSONRepresentable {
  public let project: String
  public let requestedPermissions: [String]
  public let grantedPermissions: [String]

  public func gatewayJSONValue() -> JSONValue {
    .object([
      "project": .string(project),
      "requestedPermissions": .array(requestedPermissions.map(JSONValue.string)),
      "grantedPermissions": .array(grantedPermissions.map(JSONValue.string)),
      "missingPermissions": .array(
        requestedPermissions.filter { !grantedPermissions.contains($0) }.map(JSONValue.string))
    ])
  }
}

public struct GoogleProjectIAMClient: Sendable {
  private let transport: any GatewayHTTPTransport
  private let tokenProvider: any AccessTokenProvider
  private let baseURL: URL

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    tokenProvider: any AccessTokenProvider,
    baseURL: URL = URL(string: "https://cloudresourcemanager.googleapis.com")!
  ) {
    self.transport = transport
    self.tokenProvider = tokenProvider
    self.baseURL = baseURL
  }

  public func testPermissions(project inputProject: String, permissions input: [String]) async throws
    -> ProjectPermissionTestResult {
    let project = try GatewayValidation.project(inputProject)
    let permissions = try GatewayValidation.iamPermissions(input)
    let token = try await tokenProvider.accessToken()
    let url = baseURL
      .appending(path: "v3")
      .appending(path: project)
      .appending(path: ":testIamPermissions")
    let body = try GatewayJSONCodec.encode(
      .object(["permissions": .array(permissions.map(JSONValue.string))]))
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(
        GatewayHTTPRequest(
          method: "POST", url: url,
          headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
          body: body))
    } catch let error as GatewayError {
      throw Redactor.redact(error, token: token)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw iamProviderError(response, token: token)
    }
    guard case .object(let object) = try GatewayJSONCodec.decode(response.body) else {
      throw GatewayError(.malformedResponse, "IAM response is invalid")
    }
    let values: [JSONValue]
    switch object["permissions"] {
    case .array(let array): values = array
    case nil: values = []
    default: throw GatewayError(.malformedResponse, "IAM response is invalid")
    }
    let granted = try values.map { value -> String in
      guard case .string(let permission) = value, permissions.contains(permission) else {
        throw GatewayError(.malformedResponse, "IAM response contains an unexpected permission")
      }
      return permission
    }
    guard Set(granted).count == granted.count else {
      throw GatewayError(.malformedResponse, "IAM response contains duplicate permissions")
    }
    return ProjectPermissionTestResult(
      project: project, requestedPermissions: permissions, grantedPermissions: granted.sorted())
  }
}

private func iamProviderError(_ response: GatewayHTTPResponse, token: String) -> GatewayError {
  let value = try? GatewayJSONCodec.decode(response.body)
  let outer: [String: JSONValue]? = if case .object(let object) = value { object } else { nil }
  let nested: [String: JSONValue]? = if case .object(let object) = outer?["error"] {
    object
  } else {
    outer
  }
  let message: String = if case .string(let text) = nested?["message"] {
    Redactor.scrub(text, token: token)
  } else {
    "IAM provider request failed"
  }
  let status: String? = if case .string(let text) = nested?["status"] { text } else { nil }
  let code: GatewayErrorCode = switch (status, response.statusCode) {
  case ("UNAUTHENTICATED", _), (_, 401): .authenticationFailed
  case ("PERMISSION_DENIED", _), (_, 403): .permissionDenied
  case ("NOT_FOUND", _), (_, 404): .notFound
  case ("INVALID_ARGUMENT", _), (_, 400): .invalidArgument
  case ("RESOURCE_EXHAUSTED", _), (_, 429): .rateLimited
  default: .providerError
  }
  return GatewayError(
    code, message, httpStatus: response.statusCode, googleStatus: status,
    details: value.map { [Redactor.redact($0, token: token)] })
}
