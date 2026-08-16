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
  private let serviceAccountSigner: any ServiceAccountJWTSigner

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    vault: OAuthCredentialVault = OAuthCredentialVault(),
    serviceAccountSigner: any ServiceAccountJWTSigner = OpenSSLServiceAccountJWTSigner()
  ) {
    self.transport = transport
    self.vault = vault
    self.serviceAccountSigner = serviceAccountSigner
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
    guard arguments.count >= 2, ["projects", "services", "api-keys"].contains(arguments[0]) else {
      return failure(
        GatewayError(.invalidArgument, "unknown writer command"), command: command, pretty: false)
    }
    if arguments[0] == "services", ["list", "get"].contains(arguments[1]) {
      return failure(
        GatewayError(.invalidArgument, "writer does not support read commands"), command: command,
        pretty: false)
    }
    let isDeleteCommand = ["projects", "api-keys"].contains(arguments[0])
      && ["delete", "undelete"].contains(arguments[1])
    if isDeleteCommand {
      return failure(
        GatewayError(.invalidArgument, "writer does not support delete commands"),
        command: command,
        pretty: false
      )
    }
    do {
      let parsed = try WriterArguments(arguments)
      let provider: any AccessTokenProvider
      if let profile = parsed.oauthProfile {
        provider = RefreshingOAuthAccessTokenProvider(profile: profile, vault: vault)
      } else if let environmentName = parsed.serviceAccountEnvironment {
        let name = try GatewayValidation.tokenEnvironmentName(environmentName)
        guard let credential = environment[name], !credential.isEmpty else {
          throw GatewayError(.authRequired, "service-account credential JSON is required")
        }
        provider = try ServiceAccountAccessTokenProvider(
          credentialJSON: credential, transport: transport, signer: serviceAccountSigner)
      } else {
        let name = try GatewayValidation.tokenEnvironmentName(parsed.tokenEnvironment)
        guard let token = environment[name], !token.isEmpty else {
          throw GatewayError(.authRequired, "access token is required")
        }
        provider = StaticAccessTokenProvider(token: token)
      }
      switch parsed.command {
      case .projectCreate:
        let client = GoogleProjectProvisioningClient(
          transport: transport,
          tokenProvider: provider
        )
        return success(
          command: "projects.create",
          data: try await client.create(try parsed.createProjectRequest()),
          pretty: parsed.pretty
        )
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
    Usage: google-service-gateway-writer <projects|services|api-keys> <command> [options]
      projects create --project-id ID --display-name NAME [--parent RESOURCE] [--label KEY=VALUE ...]
        [--service SERVICE ...] [--scope ALIAS-OR-URI ...] [polling options]
      services enable --service SERVICE [polling options]
      services disable --service SERVICE [--disable-dependents] [--check-usage] [polling options]
      services batch-enable --service SERVICE [--service SERVICE ...] [polling options]
      api-keys create --project PROJECT --display-name NAME --api-target SERVICE [restriction options] [polling options]
      api-keys restrict --key RESOURCE --api-target SERVICE [--display-name NAME] [restriction options] [polling options]
      api-keys get-key-string --key RESOURCE
    Restriction options: --allowed-ip CIDR | --allowed-referrer PATTERN | --allowed-bundle-id ID
    Polling options: --no-wait | --poll-interval SECONDS --timeout SECONDS
    Authentication: --oauth-profile NAME, --service-account-env NAME, or --access-token-env NAME
    """
  }
}

private enum WriterCommand {
  case projectCreate
  case enable(String)
  case disable(String)
  case batchEnable([String])
  case apiKeyCreate
  case apiKeyRestrict(String)
  case apiKeyString(String)
}

private func writerCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 2 else { return nil }
  return switch (arguments[0], arguments[1]) {
  case ("projects", "create"): "projects.create"
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
  case ("projects", "delete"): "projects.delete"
  case ("projects", "undelete"): "projects.undelete"
  default: nil
  }
}

private struct WriterArguments {
  let command: WriterCommand
  let projectOption: String?
  let projectID: String?
  let parent: String?
  let billingAccount: String?
  let labels: [String: String]
  let oauthScopes: [String]
  let projectServices: [String]
  let tokenEnvironment: String
  let oauthProfile: String?
  let serviceAccountEnvironment: String?
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
    let parsed = try WriterOptionState.parse(arguments)
    command = try validatedWriterCommand(arguments, parsed)
    projectOption = parsed.project
    projectID = parsed.projectID
    parent = parsed.parent
    billingAccount = parsed.billingAccount
    labels = parsed.labels
    oauthScopes = parsed.oauthScopes
    projectServices = parsed.services
    tokenEnvironment = parsed.tokenEnvironment
    oauthProfile = parsed.oauthProfile
    serviceAccountEnvironment = parsed.serviceAccountEnvironment
    pretty = parsed.pretty
    options = MutationOptions(
      wait: !parsed.noWait, pollInterval: parsed.pollInterval, timeout: parsed.timeout)
    disableDependents = parsed.disableDependents
    checkUsage = parsed.checkUsage
    displayName = parsed.displayName
    keyID = parsed.keyID
    apiTargets = parsed.apiTargets
    allowedIPs = parsed.allowedIPs
    allowedReferrers = parsed.allowedReferrers
    allowedBundleIDs = parsed.allowedBundleIDs
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

  func createProjectRequest() throws -> CreateProjectRequest {
    guard let projectID else {
      throw GatewayError(.invalidArgument, "--project-id is required")
    }
    return CreateProjectRequest(
      projectID: projectID,
      displayName: try requiredDisplayName(),
      parent: parent,
      labels: labels,
      billingAccount: billingAccount,
      services: projectServices,
      oauthScopes: oauthScopes,
      options: options
    )
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

private struct WriterOptionState {
  var project: String?
  var projectID: String?
  var parent: String?
  var billingAccount: String?
  var labels: [String: String] = [:]
  var oauthScopes: [String] = []
  var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
  var tokenEnvironmentSpecified = false
  var oauthProfile: String?
  var serviceAccountEnvironment: String?
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

  static func parse(_ arguments: [String]) throws -> WriterOptionState {
    var parsed = WriterOptionState()
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
      case "--project": parsed.project = try value()
      case "--project-id": parsed.projectID = try value()
      case "--parent": parsed.parent = try value()
      case "--billing-account": parsed.billingAccount = try value()
      case "--label": try parsed.addLabel(value())
      case "--scope": parsed.oauthScopes.append(try value())
      case "--access-token-env":
        parsed.tokenEnvironment = try value()
        parsed.tokenEnvironmentSpecified = true
      case "--oauth-profile": parsed.oauthProfile = try value()
      case "--service-account-env": parsed.serviceAccountEnvironment = try value()
      case "--pretty": parsed.pretty = true
      case "--service": parsed.services.append(try value())
      case "--key": parsed.key = try value()
      case "--display-name": parsed.displayName = try value()
      case "--key-id": parsed.keyID = try value()
      case "--api-target": parsed.apiTargets.append(try value())
      case "--allowed-ip": parsed.allowedIPs.append(try value())
      case "--allowed-referrer": parsed.allowedReferrers.append(try value())
      case "--allowed-bundle-id": parsed.allowedBundleIDs.append(try value())
      case "--no-wait": parsed.noWait = true
      case "--poll-interval":
        parsed.pollInterval = try pollingValue(value(), name: "poll interval")
        parsed.specifiedPolling = true
      case "--timeout":
        parsed.timeout = try pollingValue(value(), name: "timeout")
        parsed.specifiedPolling = true
      case "--disable-dependents": parsed.disableDependents = true
      case "--check-usage": parsed.checkUsage = true
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    try parsed.validateSharedOptions()
    return parsed
  }

  mutating func addLabel(_ entry: String) throws {
    let components = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard components.count == 2, !components[0].isEmpty else {
      throw GatewayError(.invalidArgument, "--label requires KEY=VALUE")
    }
    let key = String(components[0])
    guard labels[key] == nil else {
      throw GatewayError(.invalidArgument, "duplicate project label")
    }
    labels[key] = String(components[1])
  }

  func validateSharedOptions() throws {
    guard !(noWait && specifiedPolling) else {
      throw GatewayError(.invalidArgument, "--no-wait cannot be combined with polling options")
    }
    guard [tokenEnvironmentSpecified, oauthProfile != nil, serviceAccountEnvironment != nil]
      .filter({ $0 }).count <= 1
    else {
      throw GatewayError(
        .invalidArgument, "authentication options cannot be combined")
    }
    let restrictionKinds = [
      !allowedIPs.isEmpty, !allowedReferrers.isEmpty, !allowedBundleIDs.isEmpty
    ].filter { $0 }.count
    guard restrictionKinds <= 1 else {
      throw GatewayError(
        .invalidArgument, "API key client restriction kinds are mutually exclusive")
    }
  }

  var apiOptionsUsed: Bool {
    key != nil || displayName != nil || keyID != nil || !apiTargets.isEmpty || !allowedIPs.isEmpty
      || !allowedReferrers.isEmpty || !allowedBundleIDs.isEmpty
  }

  var projectOptionsUsed: Bool {
    projectID != nil || parent != nil || billingAccount != nil || !labels.isEmpty
      || !oauthScopes.isEmpty
  }
}

private func pollingValue(_ value: String, name: String) throws -> Double {
  guard let parsed = Double(value) else {
    throw GatewayError(.invalidArgument, "invalid \(name)")
  }
  return parsed
}

private func validatedWriterCommand(
  _ arguments: [String],
  _ parsed: WriterOptionState
) throws -> WriterCommand {
  switch (arguments[0], arguments[1]) {
  case ("projects", "create"):
    guard parsed.project == nil, parsed.projectID != nil, parsed.displayName != nil,
      parsed.billingAccount == nil,
      parsed.key == nil, parsed.keyID == nil, parsed.apiTargets.isEmpty, parsed.allowedIPs.isEmpty,
      parsed.allowedReferrers.isEmpty, parsed.allowedBundleIDs.isEmpty,
      !parsed.disableDependents, !parsed.checkUsage
    else { throw writerInvalidOptions() }
    return .projectCreate
  case ("services", "enable"):
    guard parsed.services.count == 1, let service = parsed.services.first,
      !parsed.disableDependents, !parsed.checkUsage, !parsed.apiOptionsUsed,
      !parsed.projectOptionsUsed
    else { throw writerInvalidOptions() }
    return .enable(service)
  case ("services", "disable"):
    guard parsed.services.count == 1, let service = parsed.services.first,
      !parsed.apiOptionsUsed, !parsed.projectOptionsUsed
    else { throw writerInvalidOptions() }
    return .disable(service)
  case ("services", "batch-enable"):
    guard !parsed.services.isEmpty, !parsed.disableDependents, !parsed.checkUsage,
      !parsed.apiOptionsUsed, !parsed.projectOptionsUsed
    else { throw writerInvalidOptions() }
    return .batchEnable(parsed.services)
  case ("api-keys", "create"):
    guard parsed.project != nil, parsed.key == nil, parsed.displayName != nil,
      !parsed.apiTargets.isEmpty, parsed.services.isEmpty, !parsed.disableDependents,
      !parsed.checkUsage, !parsed.projectOptionsUsed
    else { throw writerInvalidOptions() }
    return .apiKeyCreate
  case ("api-keys", "restrict"):
    guard parsed.project == nil, let key = parsed.key, parsed.keyID == nil,
      !parsed.apiTargets.isEmpty, parsed.services.isEmpty, !parsed.disableDependents,
      !parsed.checkUsage, !parsed.projectOptionsUsed
    else { throw writerInvalidOptions() }
    return .apiKeyRestrict(key)
  case ("api-keys", "get-key-string"):
    guard parsed.validNamedAPIKeyCommand, !parsed.noWait, !parsed.specifiedPolling,
      let key = parsed.key
    else { throw writerInvalidOptions() }
    return .apiKeyString(key)
  default:
    throw GatewayError(.invalidArgument, "unknown writer command")
  }
}

extension WriterOptionState {
  fileprivate var validNamedAPIKeyCommand: Bool {
    project == nil && key != nil && displayName == nil && keyID == nil && apiTargets.isEmpty
      && allowedIPs.isEmpty && allowedReferrers.isEmpty && allowedBundleIDs.isEmpty
      && services.isEmpty && !disableDependents && !checkUsage && !projectOptionsUsed
  }
}

private func writerInvalidOptions() -> GatewayError {
  GatewayError(.invalidArgument, "options are not valid for this command")
}

private func success<DataValue: GatewayJSONRepresentable>(
  command: String, data: DataValue, pretty: Bool
) -> WriterExecution {
  let envelope: JSONValue = .object([
    "ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue()
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
