import Foundation
import GoogleServiceGatewayCore

public struct DeleterExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public struct DeleterAdapter: Sendable {
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
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> DeleterExecution {
    let command = deleterCommandName(arguments)
    if arguments.contains("--help") || arguments.contains("-h") {
      return .init(output: usage, isError: false, exitStatus: 0)
    }
    if arguments.contains("--version") {
      return .init(output: Version.current, isError: false, exitStatus: 0)
    }
    do {
      let parsed = try DeleterArguments(arguments)
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
      case .projectDelete:
        let client = GoogleProjectProvisioningClient(
          transport: transport, tokenProvider: provider)
        return deleterSuccess(
          command: "projects.delete",
          data: try await client.delete(
            project: try parsed.project(environment), options: parsed.options),
          pretty: parsed.pretty
        )
      case .projectUndelete:
        let client = GoogleProjectProvisioningClient(
          transport: transport, tokenProvider: provider)
        return deleterSuccess(
          command: "projects.undelete",
          data: try await client.undelete(
            project: try parsed.project(environment), options: parsed.options),
          pretty: parsed.pretty
        )
      case .apiKeyDelete(let key):
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: provider)
        return deleterSuccess(
          command: "api-keys.delete",
          data: try await client.delete(key, options: parsed.options),
          pretty: parsed.pretty
        )
      case .apiKeyUndelete(let key):
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: provider)
        return deleterSuccess(
          command: "api-keys.undelete",
          data: try await client.undelete(key, options: parsed.options),
          pretty: parsed.pretty
        )
      }
    } catch let error as GatewayError {
      return deleterFailure(error, command: command, pretty: arguments.contains("--pretty"))
    } catch is CancellationError {
      return deleterFailure(
        GatewayError(.cancelled, "operation cancelled"), command: command, pretty: false)
    } catch {
      return deleterFailure(
        GatewayError(.unexpectedError, "unexpected error"), command: command, pretty: false)
    }
  }

  private var usage: String {
    """
    Usage: google-service-gateway-deleter <projects|api-keys> <command> [options]
      projects delete [--project PROJECT] [polling options]
      projects undelete [--project PROJECT] [polling options]
      api-keys delete --key RESOURCE [polling options]
      api-keys undelete --key RESOURCE [polling options]
    Polling options: --no-wait | --poll-interval SECONDS --timeout SECONDS
    Authentication: --oauth-profile NAME, --service-account-env NAME, or --access-token-env NAME
    """
  }
}

private enum DeleterCommand {
  case projectDelete
  case projectUndelete
  case apiKeyDelete(String)
  case apiKeyUndelete(String)
}

private func deleterCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 2 else { return nil }
  return switch (arguments[0], arguments[1]) {
  case ("projects", "delete"): "projects.delete"
  case ("projects", "undelete"): "projects.undelete"
  case ("api-keys", "delete"): "api-keys.delete"
  case ("api-keys", "undelete"): "api-keys.undelete"
  default: nil
  }
}

private struct DeleterArguments {
  let command: DeleterCommand
  let projectOption: String?
  let tokenEnvironment: String
  let oauthProfile: String?
  let serviceAccountEnvironment: String?
  let pretty: Bool
  let options: MutationOptions

  init(_ arguments: [String]) throws {
    guard arguments.count >= 2 else {
      throw GatewayError(.invalidArgument, "deleter command is required")
    }
    var project: String?
    var key: String?
    var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    var tokenEnvironmentSpecified = false
    var oauthProfile: String?
    var serviceAccountEnvironment: String?
    var pretty = false
    var noWait = false
    var pollInterval = 1.0
    var timeout = 120.0
    var specifiedPolling = false
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
      case "--key": key = try value()
      case "--access-token-env":
        tokenEnvironment = try value()
        tokenEnvironmentSpecified = true
      case "--oauth-profile": oauthProfile = try value()
      case "--service-account-env": serviceAccountEnvironment = try value()
      case "--pretty": pretty = true
      case "--no-wait": noWait = true
      case "--poll-interval":
        pollInterval = try deleterPollingValue(value(), name: "poll interval")
        specifiedPolling = true
      case "--timeout":
        timeout = try deleterPollingValue(value(), name: "timeout")
        specifiedPolling = true
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    guard !(noWait && specifiedPolling) else {
      throw GatewayError(.invalidArgument, "--no-wait cannot be combined with polling options")
    }
    guard [tokenEnvironmentSpecified, oauthProfile != nil, serviceAccountEnvironment != nil]
      .filter({ $0 }).count <= 1
    else {
      throw GatewayError(
        .invalidArgument, "authentication options cannot be combined")
    }
    switch (arguments[0], arguments[1]) {
    case ("projects", "delete"):
      guard key == nil else { throw deleterInvalidOptions() }
      command = .projectDelete
    case ("projects", "undelete"):
      guard key == nil else { throw deleterInvalidOptions() }
      command = .projectUndelete
    case ("api-keys", "delete"):
      guard project == nil, let key else { throw deleterInvalidOptions() }
      command = .apiKeyDelete(key)
    case ("api-keys", "undelete"):
      guard project == nil, let key else { throw deleterInvalidOptions() }
      command = .apiKeyUndelete(key)
    default:
      throw GatewayError(.invalidArgument, "unknown deleter command")
    }
    projectOption = project
    self.tokenEnvironment = tokenEnvironment
    self.oauthProfile = oauthProfile
    self.serviceAccountEnvironment = serviceAccountEnvironment
    self.pretty = pretty
    options = MutationOptions(wait: !noWait, pollInterval: pollInterval, timeout: timeout)
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
}

private func deleterPollingValue(_ value: String, name: String) throws -> Double {
  guard let parsed = Double(value) else {
    throw GatewayError(.invalidArgument, "invalid \(name)")
  }
  return parsed
}

private func deleterInvalidOptions() -> GatewayError {
  GatewayError(.invalidArgument, "options are not valid for this command")
}

private func deleterSuccess<DataValue: GatewayJSONRepresentable>(
  command: String,
  data: DataValue,
  pretty: Bool
) -> DeleterExecution {
  let envelope: JSONValue = .object([
    "ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue()
  ])
  let output =
    String(
      data: (try? GatewayJSONCodec.encode(envelope, pretty: pretty)) ?? Data("{\"ok\":true}".utf8),
      encoding: .utf8) ?? "{\"ok\":true}"
  return DeleterExecution(output: output, isError: false, exitStatus: 0)
}

private func deleterFailure(
  _ error: GatewayError,
  command: String?,
  pretty: Bool
) -> DeleterExecution {
  var envelope: [String: JSONValue] = ["ok": .bool(false), "error": error.gatewayJSONValue()]
  if let command { envelope["command"] = .string(command) }
  let output =
    String(
      data: (try? GatewayJSONCodec.encode(.object(envelope), pretty: pretty))
        ?? Data("{\"ok\":false}".utf8), encoding: .utf8) ?? "{\"ok\":false}"
  return DeleterExecution(output: output, isError: true, exitStatus: error.code.exitStatus)
}
