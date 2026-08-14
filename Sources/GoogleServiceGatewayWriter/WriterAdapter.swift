import Foundation
import GoogleServiceGatewayCore

public struct WriterExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public struct WriterAdapter: Sendable {
  private let transport: any GatewayHTTPTransport

  public init(transport: any GatewayHTTPTransport = URLSessionGatewayTransport()) {
    self.transport = transport
  }

  public func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> WriterExecution {
    let command = writerCommandName(arguments)
    if arguments.contains("--help") || arguments.contains("-h") { return .init(output: usage, isError: false, exitStatus: 0) }
    if arguments.contains("--version") { return .init(output: Version.current, isError: false, exitStatus: 0) }
    guard arguments.count >= 2, arguments[0] == "services" else {
      return failure(GatewayError(.invalidArgument, "unknown writer command"), command: command, pretty: false)
    }
    if ["list", "get"].contains(arguments[1]) {
      return failure(GatewayError(.invalidArgument, "writer does not support read commands"), command: command, pretty: false)
    }
    do {
      let parsed = try WriterArguments(arguments)
      let name = try GatewayValidation.tokenEnvironmentName(parsed.tokenEnvironment)
      guard let token = environment[name], !token.isEmpty else { throw GatewayError(.authRequired, "access token is required") }
      let project = try parsed.project(environment)
      let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: token))
      switch parsed.command {
      case .enable(let service):
        return success(command: "services.enable", data: try await client.enable(project: project, service: service, options: parsed.options), pretty: parsed.pretty)
      case .disable(let service):
        return success(command: "services.disable", data: try await client.disable(project: project, service: service, disableDependents: parsed.disableDependents, checkUsage: parsed.checkUsage, options: parsed.options), pretty: parsed.pretty)
      case .batchEnable(let services):
        return success(command: "services.batch-enable", data: try await client.batchEnable(project: project, services: services, options: parsed.options), pretty: parsed.pretty)
      }
    } catch let error as GatewayError {
      return failure(error, command: command, pretty: arguments.contains("--pretty"))
    } catch is CancellationError {
      return failure(GatewayError(.cancelled, "operation cancelled"), command: command, pretty: false)
    } catch {
      return failure(GatewayError(.unexpectedError, "unexpected error"), command: command, pretty: false)
    }
  }

  private var usage: String {
    """
    Usage: google-service-gateway-writer services <enable|disable|batch-enable> [options]
      services enable --service <alias|service-id> [--no-wait] [--poll-interval seconds] [--timeout seconds]
      services disable --service <alias|service-id> [--disable-dependents] [--check-usage] [--no-wait] [--poll-interval seconds] [--timeout seconds]
      services batch-enable --service <alias|service-id> [--service <alias|service-id> ...] [--no-wait] [--poll-interval seconds] [--timeout seconds]
    """
  }
}

private enum WriterCommand { case enable(String), disable(String), batchEnable([String]) }

private func writerCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 2, arguments[0] == "services" else { return nil }
  return switch arguments[1] {
  case "enable": "services.enable"
  case "disable": "services.disable"
  case "batch-enable": "services.batch-enable"
  case "list": "services.list"
  case "get": "services.get"
  default: nil
  }
}

private struct WriterArguments {
  let command: WriterCommand
  let projectOption: String?
  let tokenEnvironment: String
  let pretty: Bool
  let options: MutationOptions
  let disableDependents: Bool
  let checkUsage: Bool

  init(_ arguments: [String]) throws {
    guard arguments.count >= 2, arguments[0] == "services" else { throw GatewayError(.invalidArgument, "writer command is required") }
    var index = 2
    var project: String?
    var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    var pretty = false
    var services: [String] = []
    var noWait = false
    var pollInterval = 1.0
    var timeout = 120.0
    var specifiedPolling = false
    var disableDependents = false
    var checkUsage = false
    while index < arguments.count {
      let argument = arguments[index]
      func value() throws -> String {
        guard index + 1 < arguments.count else { throw GatewayError(.invalidArgument, "\(argument) requires a value") }
        index += 1
        return arguments[index]
      }
      switch argument {
      case "--project": project = try value()
      case "--access-token-env": tokenEnvironment = try value()
      case "--pretty": pretty = true
      case "--service": services.append(try value())
      case "--no-wait": noWait = true
      case "--poll-interval":
        guard let value = Double(try value()) else { throw GatewayError(.invalidArgument, "invalid poll interval") }
        pollInterval = value
        specifiedPolling = true
      case "--timeout":
        guard let value = Double(try value()) else { throw GatewayError(.invalidArgument, "invalid timeout") }
        timeout = value
        specifiedPolling = true
      case "--disable-dependents": disableDependents = true
      case "--check-usage": checkUsage = true
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    guard !(noWait && specifiedPolling) else { throw GatewayError(.invalidArgument, "--no-wait cannot be combined with polling options") }
    let commandName = arguments[1]
    switch commandName {
    case "enable":
      guard services.count == 1, let service = services.first else { throw GatewayError(.invalidArgument, "enable requires one --service") }
      guard !disableDependents, !checkUsage else { throw GatewayError(.invalidArgument, "disable options are not accepted for enable") }
      command = .enable(service)
    case "disable":
      guard services.count == 1, let service = services.first else { throw GatewayError(.invalidArgument, "disable requires one --service") }
      command = .disable(service)
    case "batch-enable":
      guard !disableDependents, !checkUsage else { throw GatewayError(.invalidArgument, "disable options are not accepted for batch-enable") }
      command = .batchEnable(services)
    default: throw GatewayError(.invalidArgument, "unknown writer command")
    }
    self.projectOption = project
    self.tokenEnvironment = tokenEnvironment
    self.pretty = pretty
    self.options = MutationOptions(wait: !noWait, pollInterval: pollInterval, timeout: timeout)
    self.disableDependents = disableDependents
    self.checkUsage = checkUsage
  }

  func project(_ environment: [String: String]) throws -> String {
    let value = projectOption ?? environment["GOOGLE_SERVICE_GATEWAY_PROJECT"] ?? environment["GOOGLE_CLOUD_PROJECT"]
    guard let value, !value.isEmpty else { throw GatewayError(.configurationError, "project is required") }
    return value
  }
}

private func success<DataValue: GatewayJSONRepresentable>(command: String, data: DataValue, pretty: Bool) -> WriterExecution {
  let envelope: JSONValue = .object(["ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue()])
  let output = String(data: (try? GatewayJSONCodec.encode(envelope, pretty: pretty)) ?? Data("{\"ok\":true}".utf8), encoding: .utf8)!
  return WriterExecution(output: output, isError: false, exitStatus: 0)
}

private func failure(_ error: GatewayError, command: String?, pretty: Bool) -> WriterExecution {
  var envelope: [String: JSONValue] = ["ok": .bool(false), "error": error.gatewayJSONValue()]
  if let command { envelope["command"] = .string(command) }
  let output = String(data: (try? GatewayJSONCodec.encode(.object(envelope), pretty: pretty)) ?? Data("{\"ok\":false}".utf8), encoding: .utf8)!
  return WriterExecution(output: output, isError: true, exitStatus: error.code.exitStatus)
}
