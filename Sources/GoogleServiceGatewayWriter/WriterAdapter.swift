import Foundation
import GoogleServiceGatewayCore

public struct WriterExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public struct WriterAdapter: Sendable {
  private let transport: any GatewayHTTPTransport
  private let vault: OAuthCredentialVault

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    vault: OAuthCredentialVault = OAuthCredentialVault()
  ) {
    self.transport = transport
    self.vault = vault
  }

  public func run(
    arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> WriterExecution {
    let command = writerCommandName(arguments)
    if arguments.contains("--help") || arguments.contains("-h") {
      return .init(output: usage, isError: false, exitStatus: 0)
    }
    if arguments.contains("--version") {
      return .init(output: Version.current, isError: false, exitStatus: 0)
    }
    guard arguments.count >= 2, ["services", "api-keys"].contains(arguments[0]) else {
      return failure(
        GatewayError(.invalidArgument, "unknown writer command"), command: command, pretty: false)
    }
    if arguments[0] == "services", ["list", "get"].contains(arguments[1]) {
      return failure(
        GatewayError(.invalidArgument, "writer does not support read commands"), command: command,
        pretty: false)
    }
    do {
      let parsed = try WriterArguments(arguments)
      let provider: any AccessTokenProvider
      if let profile = parsed.oauthProfile {
        provider = RefreshingOAuthAccessTokenProvider(profile: profile, vault: vault)
      } else {
        let name = try GatewayValidation.tokenEnvironmentName(parsed.tokenEnvironment)
        guard let token = environment[name], !token.isEmpty else {
          throw GatewayError(.authRequired, "access token is required")
        }
        provider = StaticAccessTokenProvider(token: token)
      }
      switch parsed.command {
      case .enable(let service):
        let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: provider)
        return success(
          command: "services.enable",
          data: try await client.enable(
            project: try parsed.project(environment), service: service, options: parsed.options),
          pretty: parsed.pretty)
      case .disable(let service):
        let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: provider)
        return success(
          command: "services.disable",
          data: try await client.disable(
            project: try parsed.project(environment), service: service,
            disableDependents: parsed.disableDependents, checkUsage: parsed.checkUsage,
            options: parsed.options), pretty: parsed.pretty)
      case .batchEnable(let services):
        let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: provider)
        return success(
          command: "services.batch-enable",
          data: try await client.batchEnable(
            project: try parsed.project(environment), services: services, options: parsed.options),
          pretty: parsed.pretty)
      case .apiKeyCreate:
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: provider)
        let request = CreateAPIKeyRequest(
          project: try parsed.project(environment),
          displayName: try parsed.requiredDisplayName(),
          keyID: parsed.keyID,
          restrictions: try parsed.apiKeyRestrictions(),
          options: parsed.options
        )
        return success(
          command: "api-keys.create", data: try await client.create(request), pretty: parsed.pretty)
      case .apiKeyRestrict(let key):
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: provider)
        return success(
          command: "api-keys.restrict",
          data: try await client.restrict(
            key, displayName: parsed.displayName, restrictions: try parsed.apiKeyRestrictions(),
            options: parsed.options), pretty: parsed.pretty)
      case .apiKeyString(let key):
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: provider)
        return success(
          command: "api-keys.get-key-string", data: try await client.getKeyString(key),
          pretty: parsed.pretty)
      case .apiKeyDelete(let key):
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: provider)
        return success(
          command: "api-keys.delete", data: try await client.delete(key, options: parsed.options),
          pretty: parsed.pretty)
      case .apiKeyUndelete(let key):
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: provider)
        return success(
          command: "api-keys.undelete",
          data: try await client.undelete(key, options: parsed.options), pretty: parsed.pretty)
      }
    } catch let error as GatewayError {
      return failure(error, command: command, pretty: arguments.contains("--pretty"))
    } catch is CancellationError {
      return failure(
        GatewayError(.cancelled, "operation cancelled"), command: command, pretty: false)
    } catch {
      return failure(
        GatewayError(.unexpectedError, "unexpected error"), command: command, pretty: false)
    }
  }

  private var usage: String {
    """
    Usage: google-service-gateway-writer <services|api-keys> <command> [options]
      services enable --service SERVICE [polling options]
      services disable --service SERVICE [--disable-dependents] [--check-usage] [polling options]
      services batch-enable --service SERVICE [--service SERVICE ...] [polling options]
      api-keys create --project PROJECT --display-name NAME --api-target SERVICE [restriction options] [polling options]
      api-keys restrict --key RESOURCE --api-target SERVICE [--display-name NAME] [restriction options] [polling options]
      api-keys get-key-string --key RESOURCE
      api-keys delete --key RESOURCE [polling options]
      api-keys undelete --key RESOURCE [polling options]
    Restriction options: --allowed-ip CIDR | --allowed-referrer PATTERN | --allowed-bundle-id ID
    Polling options: --no-wait | --poll-interval SECONDS --timeout SECONDS
    Authentication: --oauth-profile NAME or --access-token-env NAME
    """
  }
}

private enum WriterCommand {
  case enable(String)
  case disable(String)
  case batchEnable([String])
  case apiKeyCreate
  case apiKeyRestrict(String)
  case apiKeyString(String)
  case apiKeyDelete(String)
  case apiKeyUndelete(String)
}

private func writerCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 2 else { return nil }
  return switch (arguments[0], arguments[1]) {
  case ("services", "enable"): "services.enable"
  case ("services", "disable"): "services.disable"
  case ("services", "batch-enable"): "services.batch-enable"
  case ("services", "list"): "services.list"
  case ("services", "get"): "services.get"
  case ("api-keys", "create"): "api-keys.create"
  case ("api-keys", "restrict"): "api-keys.restrict"
  case ("api-keys", "get-key-string"): "api-keys.get-key-string"
  case ("api-keys", "delete"): "api-keys.delete"
  case ("api-keys", "undelete"): "api-keys.undelete"
  default: nil
  }
}

private struct WriterArguments {
  let command: WriterCommand
  let projectOption: String?
  let tokenEnvironment: String
  let oauthProfile: String?
  let pretty: Bool
  let options: MutationOptions
  let disableDependents: Bool
  let checkUsage: Bool
  let displayName: String?
  let keyID: String?
  let apiTargets: [String]
  let allowedIPs: [String]
  let allowedReferrers: [String]
  let allowedBundleIDs: [String]

  init(_ arguments: [String]) throws {
    guard arguments.count >= 2 else {
      throw GatewayError(.invalidArgument, "writer command is required")
    }
    var project: String?
    var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    var tokenEnvironmentSpecified = false
    var oauthProfile: String?
    var pretty = false
    var services: [String] = []
    var key: String?
    var displayName: String?
    var keyID: String?
    var apiTargets: [String] = []
    var allowedIPs: [String] = []
    var allowedReferrers: [String] = []
    var allowedBundleIDs: [String] = []
    var noWait = false
    var pollInterval = 1.0
    var timeout = 120.0
    var specifiedPolling = false
    var disableDependents = false
    var checkUsage = false
    var index = 2
    while index < arguments.count {
      let argument = arguments[index]
      func value() throws -> String {
        guard index + 1 < arguments.count else {
          throw GatewayError(.invalidArgument, "\(argument) requires a value")
        }
        index += 1
        return arguments[index]
      }
      switch argument {
      case "--project": project = try value()
      case "--access-token-env":
        tokenEnvironment = try value()
        tokenEnvironmentSpecified = true
      case "--oauth-profile": oauthProfile = try value()
      case "--pretty": pretty = true
      case "--service": services.append(try value())
      case "--key": key = try value()
      case "--display-name": displayName = try value()
      case "--key-id": keyID = try value()
      case "--api-target": apiTargets.append(try value())
      case "--allowed-ip": allowedIPs.append(try value())
      case "--allowed-referrer": allowedReferrers.append(try value())
      case "--allowed-bundle-id": allowedBundleIDs.append(try value())
      case "--no-wait": noWait = true
      case "--poll-interval":
        guard let parsed = Double(try value()) else {
          throw GatewayError(.invalidArgument, "invalid poll interval")
        }
        pollInterval = parsed
        specifiedPolling = true
      case "--timeout":
        guard let parsed = Double(try value()) else {
          throw GatewayError(.invalidArgument, "invalid timeout")
        }
        timeout = parsed
        specifiedPolling = true
      case "--disable-dependents": disableDependents = true
      case "--check-usage": checkUsage = true
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    guard !(noWait && specifiedPolling) else {
      throw GatewayError(.invalidArgument, "--no-wait cannot be combined with polling options")
    }
    let apiOptionsUsed =
      key != nil || displayName != nil || keyID != nil || !apiTargets.isEmpty || !allowedIPs.isEmpty
      || !allowedReferrers.isEmpty || !allowedBundleIDs.isEmpty
    switch (arguments[0], arguments[1]) {
    case ("services", "enable"):
      guard services.count == 1, let service = services.first, !disableDependents, !checkUsage,
        !apiOptionsUsed
      else { throw writerInvalidOptions() }
      command = .enable(service)
    case ("services", "disable"):
      guard services.count == 1, let service = services.first, !apiOptionsUsed else {
        throw writerInvalidOptions()
      }
      command = .disable(service)
    case ("services", "batch-enable"):
      guard !services.isEmpty, !disableDependents, !checkUsage, !apiOptionsUsed else {
        throw writerInvalidOptions()
      }
      command = .batchEnable(services)
    case ("api-keys", "create"):
      guard project != nil, key == nil, displayName != nil, !apiTargets.isEmpty, services.isEmpty,
        !disableDependents, !checkUsage
      else { throw writerInvalidOptions() }
      command = .apiKeyCreate
    case ("api-keys", "restrict"):
      guard project == nil, let key, keyID == nil, !apiTargets.isEmpty, services.isEmpty,
        !disableDependents, !checkUsage
      else { throw writerInvalidOptions() }
      command = .apiKeyRestrict(key)
    case ("api-keys", "get-key-string"):
      guard project == nil, let key, displayName == nil, keyID == nil, apiTargets.isEmpty,
        allowedIPs.isEmpty, allowedReferrers.isEmpty, allowedBundleIDs.isEmpty, services.isEmpty,
        !disableDependents, !checkUsage, !noWait, !specifiedPolling
      else { throw writerInvalidOptions() }
      command = .apiKeyString(key)
    case ("api-keys", "delete"):
      guard project == nil, let key, displayName == nil, keyID == nil, apiTargets.isEmpty,
        allowedIPs.isEmpty, allowedReferrers.isEmpty, allowedBundleIDs.isEmpty, services.isEmpty,
        !disableDependents, !checkUsage
      else { throw writerInvalidOptions() }
      command = .apiKeyDelete(key)
    case ("api-keys", "undelete"):
      guard project == nil, let key, displayName == nil, keyID == nil, apiTargets.isEmpty,
        allowedIPs.isEmpty, allowedReferrers.isEmpty, allowedBundleIDs.isEmpty, services.isEmpty,
        !disableDependents, !checkUsage
      else { throw writerInvalidOptions() }
      command = .apiKeyUndelete(key)
    default:
      throw GatewayError(.invalidArgument, "unknown writer command")
    }
    let restrictionKinds = [
      !allowedIPs.isEmpty, !allowedReferrers.isEmpty, !allowedBundleIDs.isEmpty,
    ].filter { $0 }.count
    guard restrictionKinds <= 1 else {
      throw GatewayError(
        .invalidArgument, "API key client restriction kinds are mutually exclusive")
    }
    projectOption = project
    guard !(tokenEnvironmentSpecified && oauthProfile != nil) else {
      throw GatewayError(
        .invalidArgument, "--oauth-profile cannot be combined with --access-token-env")
    }
    self.tokenEnvironment = tokenEnvironment
    self.oauthProfile = oauthProfile
    self.pretty = pretty
    options = MutationOptions(wait: !noWait, pollInterval: pollInterval, timeout: timeout)
    self.disableDependents = disableDependents
    self.checkUsage = checkUsage
    self.displayName = displayName
    self.keyID = keyID
    self.apiTargets = apiTargets
    self.allowedIPs = allowedIPs
    self.allowedReferrers = allowedReferrers
    self.allowedBundleIDs = allowedBundleIDs
  }

  func project(_ environment: [String: String]) throws -> String {
    let value =
      projectOption ?? environment["GOOGLE_SERVICE_GATEWAY_PROJECT"]
      ?? environment["GOOGLE_CLOUD_PROJECT"]
    guard let value, !value.isEmpty else {
      throw GatewayError(.configurationError, "project is required")
    }
    return value
  }

  func requiredDisplayName() throws -> String {
    guard let displayName else {
      throw GatewayError(.invalidArgument, "--display-name is required")
    }
    return displayName
  }

  func apiKeyRestrictions() throws -> APIKeyRestrictions {
    let client: APIKeyClientRestrictions
    if !allowedIPs.isEmpty {
      client = .server(allowedIPs: allowedIPs)
    } else if !allowedReferrers.isEmpty {
      client = .browser(allowedReferrers: allowedReferrers)
    } else if !allowedBundleIDs.isEmpty {
      client = .ios(allowedBundleIDs: allowedBundleIDs)
    } else {
      client = .none
    }
    return APIKeyRestrictions(
      apiTargets: apiTargets.map { APIKeyTarget(service: $0) }, client: client)
  }

}

private func writerInvalidOptions() -> GatewayError {
  GatewayError(.invalidArgument, "options are not valid for this command")
}

private func success<DataValue: GatewayJSONRepresentable>(
  command: String, data: DataValue, pretty: Bool
) -> WriterExecution {
  let envelope: JSONValue = .object([
    "ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue(),
  ])
  let output =
    String(
      data: (try? GatewayJSONCodec.encode(envelope, pretty: pretty)) ?? Data("{\"ok\":true}".utf8),
      encoding: .utf8) ?? "{\"ok\":true}"
  return WriterExecution(output: output, isError: false, exitStatus: 0)
}

private func failure(_ error: GatewayError, command: String?, pretty: Bool) -> WriterExecution {
  var envelope: [String: JSONValue] = ["ok": .bool(false), "error": error.gatewayJSONValue()]
  if let command { envelope["command"] = .string(command) }
  let output =
    String(
      data: (try? GatewayJSONCodec.encode(.object(envelope), pretty: pretty))
        ?? Data("{\"ok\":false}".utf8), encoding: .utf8) ?? "{\"ok\":false}"
  return WriterExecution(output: output, isError: true, exitStatus: error.code.exitStatus)
}
