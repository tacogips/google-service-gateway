import Foundation

public struct GoogleServiceQuotaClient: Sendable {
  private let transport: any GatewayHTTPTransport
  private let tokenProvider: any AccessTokenProvider

  public init(transport: any GatewayHTTPTransport = URLSessionGatewayTransport(), tokenProvider: any AccessTokenProvider) {
    self.transport = transport
    self.tokenProvider = tokenProvider
  }

  public func limits(project: String, service: String, pagination: QuotaPagination = .init()) async throws -> QuotaPage {
    try validate(pagination)
    let project = try GatewayValidation.project(project)
    let service = try GatewayValidation.service(service)
    let canonical = try await GoogleServiceGatewayClient(transport: transport, tokenProvider: tokenProvider).canonicalServiceProject(project)
    return try await page(
      kind: .limits, host: "serviceusage.googleapis.com", path: "/v1beta1/\(canonical)/services/\(service)/consumerQuotaMetrics",
      query: [URLQueryItem(name: "view", value: "FULL")], field: "metrics", pagination: pagination
    )
  }

  public func usage(_ request: QuotaUsageRequest) async throws -> QuotaPage {
    try validate(request.pagination)
    let project = try GatewayValidation.project(request.project)
    let service = try GatewayValidation.service(request.service)
    guard request.startTime.timeIntervalSince1970.isFinite, request.endTime.timeIntervalSince1970.isFinite,
          request.startTime < request.endTime else { throw invalidQuota("start time must precede end time") }
    var filter = "metric.type = \"\(request.metric.metricType)\" AND resource.type = \"\(request.metric.resourceType)\""
    filter += " AND resource.labels.service = \"\(service)\""
    if let metric = request.quotaMetric {
      guard request.metric != .requests, !metric.isEmpty, metric.count <= 512,
            metric.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) })
      else { throw invalidQuota("invalid quota metric filter") }
      filter += " AND metric.labels.quota_metric = \"\(metric)\""
    }
    let formatter = ISO8601DateFormatter()
    let start = formatter.string(from: request.startTime)
    let end = formatter.string(from: request.endTime)
    return try await page(
      kind: .usage, host: "monitoring.googleapis.com", path: "/v3/\(project)/timeSeries",
      query: [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "view", value: "FULL"),
              URLQueryItem(name: "interval.startTime", value: start), URLQueryItem(name: "interval.endTime", value: end)],
      field: "timeSeries", pagination: request.pagination, metric: request.metric, start: start, end: end
    )
  }

  public func overrides(limit: String, pagination: QuotaPagination = .init()) async throws -> QuotaPage {
    try validate(pagination)
    let limit = try quotaResource(limit, override: false)
    return try await page(
      kind: .overrides, host: "serviceusage.googleapis.com", path: "/v1beta1/\(limit)/consumerOverrides",
      field: "overrides", pagination: pagination
    )
  }

  public func createOverride(limit: String, value: Int64, dimensions: [String: String] = [:], options: MutationOptions = .init()) async throws -> JSONValue {
    let limit = try quotaResource(limit, override: false)
    guard value >= -1 else { throw invalidQuota("override value must be -1 (unlimited) or nonnegative") }
    return try await mutation(method: "POST", resource: limit + "/consumerOverrides", body: .object([
      "overrideValue": .string(String(value)), "dimensions": .object(dimensions.mapValues(JSONValue.string))
    ]), options: options)
  }

  public func updateOverride(name: String, value: Int64, options: MutationOptions = .init()) async throws -> JSONValue {
    let name = try quotaResource(name, override: true)
    guard value >= -1 else { throw invalidQuota("override value must be -1 (unlimited) or nonnegative") }
    return try await mutation(method: "PATCH", resource: name, body: .object(["overrideValue": .string(String(value))]), options: options)
  }

  public func deleteOverride(name: String, options: MutationOptions = .init()) async throws -> JSONValue {
    try await mutation(method: "DELETE", resource: quotaResource(name, override: true), options: options)
  }

  private func mutation(method: String, resource: String, body: JSONValue? = nil, options: MutationOptions) async throws -> JSONValue {
    try GatewayValidation.polling(options)
    let query = method == "PATCH" ? [URLQueryItem(name: "updateMask", value: "overrideValue")] : []
    var operation = try quotaObject(await send(host: "serviceusage.googleapis.com", path: "/v1beta1/\(resource)", method: method, query: query, body: body))
    guard case .string(let name) = operation["name"] else { throw malformedQuota() }
    _ = try GatewayValidation.operation(name)
    if options.wait {
      let deadline = ProcessInfo.processInfo.systemUptime + options.timeout
      while operation["done"] != .bool(true) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw GatewayError(.operationTimeout, "quota operation timed out", operationName: name) }
        try await Task.sleep(for: .seconds(min(options.pollInterval, remaining)))
        let encoded = "operations/" + GatewayValidation.percentEncodePathSegment(String(name.dropFirst("operations/".count)))
        operation = try quotaObject(await send(host: "serviceusage.googleapis.com", path: "/v1beta1/\(encoded)"))
        guard operation["name"] == .string(name) else { throw malformedQuota() }
      }
      if let error = operation["error"] {
        throw GatewayError(.operationFailed, "quota override operation failed", operationName: name, details: [Redactor.redact(error)])
      }
    }
    return .object(["operation": .object(operation), "waited": .bool(options.wait)])
  }

  private func page(
    kind: QuotaPage.Kind, host: String, path: String, query: [URLQueryItem] = [], field: String,
    pagination: QuotaPagination, metric: QuotaUsageMetric? = nil, start: String? = nil, end: String? = nil
  ) async throws -> QuotaPage {
    var records: [JSONValue] = []
    var next = pagination.pageToken
    var seen = Set<String>()
    var pages = 0
    repeat {
      var items = query + [URLQueryItem(name: "pageSize", value: String(pagination.pageSize))]
      if let next { items.append(URLQueryItem(name: "pageToken", value: next)) }
      let object = try quotaObject(await send(host: host, path: path, query: items))
      if let value = object[field] {
        guard case .array(let values) = value, values.allSatisfy({ if case .object = $0 { true } else { false } }) else { throw malformedQuota() }
        records += values
      }
      // Monitoring may return partial data with executionErrors even on HTTP 200.
      if let executionErrors = object["executionErrors"] {
        guard case .array(let errors) = executionErrors else { throw malformedQuota() }
        if !errors.isEmpty { throw GatewayError(.providerError, "monitoring returned partial data", details: errors.map { Redactor.redact($0) }) }
      }
      if let value = object["nextPageToken"] {
        guard case .string(let token) = value else { throw malformedQuota() }
        next = try GatewayValidation.returnedPageToken(token)
      } else { next = nil }
      pages += 1
      if let next, !seen.insert(next).inserted { throw GatewayError(.malformedResponse, "repeated quota page token") }
      if pages >= 1000, next != nil, pagination.allPages { throw GatewayError(.providerError, "quota pagination exceeded 1000 pages") }
    } while pagination.allPages && next != nil
    return QuotaPage(kind: kind, records: records, pagesFetched: pages, nextPageToken: next, metric: metric, startTime: start, endTime: end)
  }

  private func validate(_ pagination: QuotaPagination) throws {
    _ = try GatewayValidation.pageSize(pagination.pageSize)
    _ = try GatewayValidation.pageToken(pagination.pageToken)
    guard !pagination.allPages || pagination.pageToken == nil else { throw invalidQuota("page token cannot be combined with all pages") }
  }

  private func send(host: String, path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
    var components = URLComponents()
    components.scheme = "https"; components.host = host; components.percentEncodedPath = path; components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw invalidQuota("invalid quota URL") }
    let token = try await tokenProvider.accessToken()
    var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    let data = try body.map { try GatewayJSONCodec.encode($0) }
    if data != nil { headers["Content-Type"] = "application/json" }
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(.init(method: method, url: url, headers: headers, body: data))
    } catch is CancellationError {
      throw GatewayError(.cancelled, "operation cancelled")
    } catch let error as GatewayError {
      throw Redactor.redact(error, token: token)
    } catch {
      throw GatewayError(.providerError, "quota transport request failed")
    }
    guard let value = try? GatewayJSONCodec.decode(response.body) else {
      throw GatewayError(.malformedResponse, "invalid quota provider JSON", httpStatus: response.statusCode)
    }
    guard (200..<300).contains(response.statusCode) else {
      let object = try? quotaObject(value)
      let error = object?["error"] ?? value
      let providerError = try? quotaObject(error)
      let code: GatewayErrorCode = switch (providerError?["status"], response.statusCode) {
      case (.string("RESOURCE_EXHAUSTED"), _), (_, 429): .rateLimited
      case (_, 401): .authenticationFailed
      case (_, 403): .permissionDenied
      case (_, 404): .notFound
      default: .providerError
      }
      throw GatewayError(code, "quota provider request failed", httpStatus: response.statusCode, details: [Redactor.redact(error, token: token)])
    }
    return quotaScrubCredential(value, token: token)
  }
}

private func quotaScrubCredential(_ value: JSONValue, token: String) -> JSONValue {
  switch value {
  case .string(let text): .string(Redactor.scrub(text, token: token))
  case .array(let values): .array(values.map { quotaScrubCredential($0, token: token) })
  case .object(let object): .object(object.mapValues { quotaScrubCredential($0, token: token) })
  default: value
  }
}

func invalidQuota(_ message: String) -> GatewayError { GatewayError(.invalidArgument, message) }
func malformedQuota() -> GatewayError { GatewayError(.malformedResponse, "invalid quota provider response") }
func quotaObject(_ value: JSONValue) throws -> [String: JSONValue] {
  guard case .object(let object) = value else { throw malformedQuota() }
  return object
}

func quotaResource(_ name: String, override: Bool) throws -> String {
  let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  guard parts.count == (override ? 10 : 8), parts[0] == "projects", parts[2] == "services",
        parts[4] == "consumerQuotaMetrics", parts[6] == "limits",
        parts[1].utf8.allSatisfy({ (48...57).contains($0) }), !parts[1].isEmpty,
        !override || parts[8] == "consumerOverrides" else { throw invalidQuota("invalid quota resource name; use the name returned by quotas limits") }
  _ = try GatewayValidation.service(parts[3])
  for part in parts {
    guard !part.isEmpty, let decoded = part.removingPercentEncoding, decoded != ".", decoded != "..",
          part.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [37, 45, 46, 95, 126].contains($0) }),
          decoded.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }) else { throw invalidQuota("invalid quota resource name") }
  }
  return name
}
