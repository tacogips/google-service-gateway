import Foundation

public struct QuotaExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public enum QuotaRole: String, Codable, Sendable { case reader, writer, deleter }

/// Shared quota routing keeps authentication precedence identical across roles.
public struct QuotaAdapter: Sendable {
  private let role: QuotaRole
  private let transport: any GatewayHTTPTransport
  private let vault: OAuthCredentialVault
  private let signer: any ServiceAccountJWTSigner

  public init(
    role: QuotaRole, transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    vault: OAuthCredentialVault = .init(), signer: any ServiceAccountJWTSigner = OpenSSLServiceAccountJWTSigner()
  ) { self.role = role; self.transport = transport; self.vault = vault; self.signer = signer }

  public func run(arguments: [String], environment: [String: String]) async -> QuotaExecution {
    if arguments.contains("--help") || arguments.contains("-h") {
      return .init(output: Self.usage(for: role), isError: false, exitStatus: 0)
    }
    var command = "quotas"
    do {
      let parsed = try QuotaArguments(arguments, role: role)
      command = parsed.command.rawValue
      let provider = try tokenProvider(parsed, environment: environment)
      let client = GoogleServiceQuotaClient(transport: transport, tokenProvider: provider)
      let result: JSONValue
      switch parsed.command {
      case .limits:
        result = try await client.limits(project: parsed.project(environment), service: parsed.required("service"), pagination: parsed.pagination).gatewayJSONValue()
      case .usage:
        result = try await client.usage(parsed.usageRequest(environment)).gatewayJSONValue()
      case .overridesList:
        result = try await client.overrides(limit: parsed.required("limit"), pagination: parsed.pagination).gatewayJSONValue()
      case .overridesCreate:
        result = try await client.createOverride(limit: parsed.required("limit"), value: parsed.overrideValue(), dimensions: parsed.dimensions, options: parsed.options)
      case .overridesUpdate:
        result = try await client.updateOverride(name: parsed.required("name"), value: parsed.overrideValue(), options: parsed.options)
      case .overridesDelete:
        result = try await client.deleteOverride(name: parsed.required("name"), options: parsed.options)
      }
      return try encode(.object(["ok": .bool(true), "command": .string(command), "data": result]), pretty: parsed.pretty)
    } catch let error as GatewayError {
      return failure(error, command: command, pretty: arguments.contains("--pretty"))
    } catch is CancellationError {
      return failure(GatewayError(.cancelled, "operation cancelled"), command: command, pretty: false)
    } catch {
      return failure(GatewayError(.unexpectedError, "quota command failed"), command: command, pretty: false)
    }
  }

  private func tokenProvider(_ parsed: QuotaArguments, environment: [String: String]) throws -> any AccessTokenProvider {
    let tokenName = parsed.values["access-token-env"] ?? "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    if parsed.values["service-account-env"] == nil,
       let external = try GoogleServiceExternalCredentials.tokenProvider(
         environment: environment, profile: parsed.values["oauth-profile"], tokenEnvironment: tokenName,
         transport: transport, signer: signer
       ) { return external }
    if let profile = parsed.values["oauth-profile"] {
      return RefreshingOAuthAccessTokenProvider(profile: profile, vault: vault, client: GoogleOAuthClient(transport: transport))
    }
    if let name = parsed.values["service-account-env"] {
      guard let json = environment[try GatewayValidation.tokenEnvironmentName(name)], !json.isEmpty else {
        throw GatewayError(.authRequired, "service-account credential JSON is required")
      }
      return try ServiceAccountAccessTokenProvider(credentialJSON: json, transport: transport, signer: signer)
    }
    let name = try GatewayValidation.tokenEnvironmentName(tokenName)
    if let token = environment[name], !token.isEmpty { return StaticAccessTokenProvider(token: token) }
    guard parsed.values["access-token-env"] == nil else { throw GatewayError(.authRequired, "access token is required") }
    return RefreshingOAuthAccessTokenProvider(profile: "google-personal", vault: vault, client: GoogleOAuthClient(transport: transport))
  }

  private func encode(_ value: JSONValue, pretty: Bool) throws -> QuotaExecution {
    let bytes = try GatewayJSONCodec.encode(value, pretty: pretty)
    guard let output = String(bytes: bytes, encoding: .utf8) else { throw malformedQuota() }
    return .init(output: output, isError: false, exitStatus: 0)
  }

  private func failure(_ error: GatewayError, command: String, pretty: Bool) -> QuotaExecution {
    let value: JSONValue = .object(["ok": .bool(false), "command": .string(command), "error": error.gatewayJSONValue()])
    let bytes = try? GatewayJSONCodec.encode(value, pretty: pretty)
    return .init(output: bytes.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{\"ok\":false}", isError: true, exitStatus: error.code.exitStatus)
  }

  public static func usage(for role: QuotaRole) -> String {
    let commands: String
    switch role {
    case .reader:
      commands = """
      reader quotas limits --project PROJECT --service SERVICE [pagination]
      reader quotas usage --project PROJECT --service SERVICE [--metric rate|allocation|exceeded|requests]
        [--start RFC3339 --end RFC3339] [--quota-metric METRIC] [pagination]
      reader quotas overrides list --limit RESOURCE [pagination]
      Pagination: --page-size 1...200 --page-token TOKEN | --all-pages
      Usage defaults to rate quota samples over the last 24 hours, not a daily total.
      Monitoring data can be delayed; noData does not mean zero usage.
      """
    case .writer:
      commands = """
      writer quotas overrides create --limit RESOURCE --value INT64 [--dimension KEY=VALUE ...] [polling]
      writer quotas overrides update --name RESOURCE --value INT64 [polling]
      Polling: --no-wait | --poll-interval SECONDS --timeout SECONDS
      """
    case .deleter:
      commands = """
      deleter quotas overrides delete --name RESOURCE [polling]
      Polling: --no-wait | --poll-interval SECONDS --timeout SECONDS
      """
    }
    return "Quota commands (all services; existing authentication options apply):\n" + commands
      + "\nConsumer overrides cannot raise quotas above Google's approved limits; safety checks apply."
  }
}

private enum QuotaCommand: String {
  case limits = "quotas.limits", usage = "quotas.usage", overridesList = "quotas.overrides.list"
  case overridesCreate = "quotas.overrides.create", overridesUpdate = "quotas.overrides.update", overridesDelete = "quotas.overrides.delete"
}

private struct QuotaArguments {
  let command: QuotaCommand
  let values: [String: String]
  let flags: Set<String>
  let dimensions: [String: String]
  let pagination: QuotaPagination
  let options: MutationOptions
  var pretty: Bool { flags.contains("pretty") }

  init(_ arguments: [String], role: QuotaRole) throws {
    let count = arguments.count > 1 && arguments[1] == "overrides" ? 3 : 2
    guard arguments.count >= count, let command = QuotaCommand(rawValue: arguments.prefix(count).joined(separator: ".")) else {
      throw invalidQuota("unknown quota command")
    }
    let allowedCommands: [QuotaRole: Set<QuotaCommand>] = [
      .reader: [.limits, .usage, .overridesList], .writer: [.overridesCreate, .overridesUpdate], .deleter: [.overridesDelete]
    ]
    guard allowedCommands[role]?.contains(command) == true else { throw invalidQuota("quota command is not supported by this role") }
    var allowed: Set<String> = ["access-token-env", "oauth-profile", "service-account-env"]
    var flagNames: Set<String> = ["pretty"]
    switch command {
    case .limits: allowed.formUnion(["project", "service", "page-size", "page-token"]); flagNames.insert("all-pages")
    case .usage:
      allowed.formUnion(["project", "service", "metric", "start", "end", "quota-metric", "page-size", "page-token"]); flagNames.insert("all-pages")
    case .overridesList: allowed.formUnion(["limit", "page-size", "page-token"]); flagNames.insert("all-pages")
    case .overridesCreate: allowed.formUnion(["limit", "value", "dimension"])
    case .overridesUpdate: allowed.formUnion(["name", "value"])
    case .overridesDelete: allowed.insert("name")
    }
    if role != .reader { allowed.formUnion(["poll-interval", "timeout"]); flagNames.insert("no-wait") }
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var dimensions: [String: String] = [:]
    var index = count
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--") else { throw invalidQuota("unexpected positional argument") }
      let name = String(argument.dropFirst(2))
      if flagNames.contains(name) {
        guard flags.insert(name).inserted else { throw invalidQuota("duplicate quota flag") }
      } else {
        guard allowed.contains(name), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
          throw invalidQuota("unknown quota option or missing value")
        }
        index += 1
        let value = arguments[index]
        guard !value.isEmpty else { throw invalidQuota("empty quota option") }
        if name == "dimension" {
          let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
          guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, dimensions[parts[0]] == nil else { throw invalidQuota("invalid or duplicate dimension") }
          dimensions[parts[0]] = parts[1]
        } else {
          guard values[name] == nil else { throw invalidQuota("duplicate quota option") }
          values[name] = value
        }
      }
      index += 1
    }
    guard ["access-token-env", "oauth-profile", "service-account-env"].filter({ values[$0] != nil }).count <= 1 else {
      throw invalidQuota("authentication options cannot be combined")
    }
    let size = try Self.integer(values["page-size"], default: 100)
    _ = try GatewayValidation.pageSize(size)
    let pageToken = try GatewayValidation.pageToken(values["page-token"])
    guard !flags.contains("all-pages") || pageToken == nil else { throw invalidQuota("page token cannot be combined with all pages") }
    guard !flags.contains("no-wait") || values["poll-interval"] == nil && values["timeout"] == nil else {
      throw invalidQuota("no-wait cannot be combined with polling options")
    }
    let options = try MutationOptions(wait: !flags.contains("no-wait"), pollInterval: Self.number(values["poll-interval"], default: 1),
                                      timeout: Self.number(values["timeout"], default: 120))
    try GatewayValidation.polling(options)
    self.command = command; self.values = values; self.flags = flags; self.dimensions = dimensions
    self.pagination = QuotaPagination(pageSize: size, pageToken: pageToken, allPages: flags.contains("all-pages")); self.options = options
  }

  func required(_ name: String) throws -> String {
    guard let value = values[name] else { throw invalidQuota("--\(name) is required") }
    return value
  }

  func project(_ environment: [String: String]) throws -> String {
    guard let project = values["project"] ?? environment["GOOGLE_SERVICE_GATEWAY_PROJECT"] ?? environment["GOOGLE_CLOUD_PROJECT"] else {
      throw GatewayError(.configurationError, "project is required")
    }
    return project
  }

  func overrideValue() throws -> Int64 {
    guard let value = Int64(try required("value")), value >= -1 else { throw invalidQuota("invalid INT64 override value") }
    return value
  }

  func usageRequest(_ environment: [String: String]) throws -> QuotaUsageRequest {
    guard let metric = QuotaUsageMetric(rawValue: values["metric"] ?? "rate") else { throw invalidQuota("invalid usage metric") }
    let formatter = ISO8601DateFormatter()
    func date(_ input: String) throws -> Date {
      if let value = formatter.date(from: input) { return value }
      formatter.formatOptions.insert(.withFractionalSeconds)
      guard let value = formatter.date(from: input) else { throw invalidQuota("time must be RFC3339") }
      formatter.formatOptions.remove(.withFractionalSeconds)
      return value
    }
    let end = try values["end"].map(date) ?? Date()
    let start = try values["start"].map(date) ?? end.addingTimeInterval(-86400)
    return try QuotaUsageRequest(project: project(environment), service: required("service"), metric: metric,
                                 startTime: start, endTime: end, quotaMetric: values["quota-metric"], pagination: pagination)
  }

  private static func integer(_ input: String?, default fallback: Int) throws -> Int {
    guard let input else { return fallback }
    guard let value = Int(input) else { throw invalidQuota("invalid integer option") }
    return value
  }
  private static func number(_ input: String?, default fallback: Double) throws -> Double {
    guard let input else { return fallback }
    guard let value = Double(input), value.isFinite else { throw invalidQuota("invalid numeric option") }
    return value
  }
}
