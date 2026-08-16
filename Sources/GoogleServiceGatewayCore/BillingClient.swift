import Foundation

public struct GoogleCloudBillingClient: Sendable {
  private let transport: any GatewayHTTPTransport
  private let tokenProvider: any AccessTokenProvider
  private let baseURL: URL

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    tokenProvider: any AccessTokenProvider,
    baseURL: URL = URL(string: "https://cloudbilling.googleapis.com")!
  ) {
    self.transport = transport
    self.tokenProvider = tokenProvider
    self.baseURL = baseURL
  }

  public func listAccounts(pageSize: Int = 50, pageToken: String? = nil) async throws
    -> BillingAccountPage {
    let size = try GatewayValidation.billingPageSize(pageSize)
    let token = try GatewayValidation.pageToken(pageToken)
    var query = [URLQueryItem(name: "pageSize", value: String(size))]
    if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
    let response = try await send(path: "/v1/billingAccounts", query: query)
    let object = try billingObject(response.value)
    let accounts = try billingArray(object["billingAccounts"]).map(billingAccount)
    return BillingAccountPage(
      accounts: accounts,
      nextPageToken: try GatewayValidation.returnedPageToken(
        billingOptionalString(object["nextPageToken"]))
    )
  }

  public func getAccount(_ input: String) async throws -> BillingAccount {
    let account = try GatewayValidation.billingAccount(input)
    return try billingAccount(try await send(path: "/v1/\(account)").value)
  }

  public func getProjectBilling(_ input: String) async throws -> ProjectBillingInfo {
    let project = try GatewayValidation.project(input)
    return try projectBillingInfo(
      try await send(path: "/v1/\(project)/billingInfo").value,
      expectedProject: String(project.dropFirst("projects/".count))
    )
  }

  public func updateProjectBilling(project input: String, billingAccount: String?) async throws
    -> BillingMutationResult {
    let project = try GatewayValidation.project(input)
    let account = try billingAccount.map(GatewayValidation.billingAccount)
    let response = try await send(
      method: "PUT",
      path: "/v1/\(project)/billingInfo",
      body: .object(["billingAccountName": .string(account ?? "")])
    )
    let info = try projectBillingInfo(
      response.value,
      expectedProject: String(project.dropFirst("projects/".count))
    )
    guard info.billingAccount == account else {
      throw GatewayError(.malformedResponse, "billing response does not match request")
    }
    return BillingMutationResult(
      billing: info,
      providerRequestID: response.headers.first(where: {
        $0.key.caseInsensitiveCompare("x-request-id") == .orderedSame
          || $0.key.caseInsensitiveCompare("x-guploader-uploadid") == .orderedSame
      })?.value
    )
  }

  private func send(
    method: String = "GET",
    path: String,
    query: [URLQueryItem] = [],
    body: JSONValue? = nil
  ) async throws -> (value: JSONValue, headers: [String: String]) {
    let token = try await tokenProvider.accessToken()
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.path = path
    if !query.isEmpty { components?.queryItems = query }
    guard let url = components?.url else {
      throw GatewayError(.unexpectedError, "could not construct provider URL")
    }
    let data = try body.map { try GatewayJSONCodec.encode($0) }
    var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    if data != nil { headers["Content-Type"] = "application/json" }
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(
        GatewayHTTPRequest(method: method, url: url, headers: headers, body: data))
    } catch let error as GatewayError {
      throw Redactor.redact(error, token: token)
    } catch {
      throw GatewayError(.providerError, "transport request failed")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw billingProviderError(response, token: token)
    }
    do {
      return (try GatewayJSONCodec.decode(response.body), response.headers)
    } catch {
      throw GatewayError(
        .malformedResponse, "provider response could not be decoded",
        httpStatus: response.statusCode)
    }
  }
}

private func billingAccount(_ value: JSONValue) throws -> BillingAccount {
  let object = try billingObject(value)
  let name = try GatewayValidation.billingAccount(billingRequiredString(object, "name"))
  let parentAccount = try billingOptionalString(object["masterBillingAccount"])
  if let parentAccount { _ = try GatewayValidation.billingAccount(parentAccount) }
  return BillingAccount(
    name: name,
    displayName: try billingRequiredString(object, "displayName"),
    isOpen: try billingRequiredBool(object, "open"),
    parentBillingAccount: parentAccount,
    parent: try billingOptionalString(object["parent"])
  )
}

private func projectBillingInfo(_ value: JSONValue, expectedProject: String) throws
  -> ProjectBillingInfo {
  let object = try billingObject(value)
  let projectID = try billingRequiredString(object, "projectId")
  guard projectID == expectedProject else {
    throw GatewayError(.malformedResponse, "billing response does not match request")
  }
  let account = try billingOptionalString(object["billingAccountName"]).flatMap {
    $0.isEmpty ? nil : $0
  }
  if let account { _ = try GatewayValidation.billingAccount(account) }
  return ProjectBillingInfo(
    projectID: projectID,
    billingAccount: account,
    billingEnabled: try billingRequiredBool(object, "billingEnabled")
  )
}

private func billingObject(_ value: JSONValue?) throws -> [String: JSONValue] {
  guard case .object(let object) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return object
}

private func billingArray(_ value: JSONValue?) throws -> [JSONValue] {
  guard let value else { return [] }
  guard case .array(let values) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return values
}

private func billingRequiredString(_ object: [String: JSONValue], _ key: String) throws -> String {
  guard let value = try billingOptionalString(object[key]), !value.isEmpty else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return value
}

private func billingOptionalString(_ value: JSONValue?) throws -> String? {
  guard let value else { return nil }
  guard case .string(let string) = value else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return string
}

private func billingRequiredBool(_ object: [String: JSONValue], _ key: String) throws -> Bool {
  guard case .bool(let value) = object[key] else {
    throw GatewayError(.malformedResponse, "provider response could not be decoded")
  }
  return value
}

private func billingProviderError(_ response: GatewayHTTPResponse, token: String) -> GatewayError {
  let value = try? GatewayJSONCodec.decode(response.body)
  let outer = try? billingObject(value)
  let nested = try? outer.flatMap { try billingObject($0["error"] ?? .object($0)) }
  let status = try? billingOptionalString(nested?["status"])
  let message = Redactor.scrub(
    (try? billingOptionalString(nested?["message"])) ?? "provider request failed",
    token: token)
  let code: GatewayErrorCode = switch (status, response.statusCode) {
  case ("UNAUTHENTICATED", _), (_, 401): .authenticationFailed
  case ("PERMISSION_DENIED", _), (_, 403): .permissionDenied
  case ("NOT_FOUND", _), (_, 404): .notFound
  case ("FAILED_PRECONDITION", _), (_, 409): .failedPrecondition
  case ("RESOURCE_EXHAUSTED", _), (_, 429): .rateLimited
  default: .providerError
  }
  return GatewayError(
    code, message, httpStatus: response.statusCode, googleStatus: status)
}
