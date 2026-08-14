import Foundation
import GoogleServiceGatewayCore

public struct ReaderExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public struct ReaderAdapter: Sendable {
  private let transport: any GatewayHTTPTransport

  public init(transport: any GatewayHTTPTransport = URLSessionGatewayTransport()) {
    self.transport = transport
  }

  public func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> ReaderExecution {
    let command = readerCommandName(arguments)
    if arguments.contains("--help") || arguments.contains("-h") { return .init(output: usage, isError: false, exitStatus: 0) }
    if arguments.contains("--version") { return .init(output: Version.current, isError: false, exitStatus: 0) }
    guard arguments.count >= 2, arguments[0] == "services" || arguments[0] == "operations" else {
      return failure(GatewayError(.invalidArgument, "unknown reader command"), command: command, pretty: false)
    }
    if arguments[0] == "services", ["enable", "disable", "batch-enable"].contains(arguments[1]) {
      return failure(GatewayError(.invalidArgument, "reader does not support mutations"), command: command, pretty: false)
    }
    do {
      let parsed = try ReaderArguments(arguments, environment: environment)
      let client = try client(for: parsed, environment: environment)
      switch parsed.command {
      case .list:
        let result = try await client.listServices(.init(project: try parsed.project(environment), state: parsed.state, pageSize: parsed.pageSize, pageToken: parsed.pageToken, allPages: parsed.allPages))
        return success(command: "services.list", data: result, pretty: parsed.pretty)
      case .get(let service):
        let result = try await client.getService(project: try parsed.project(environment), service: service)
        return success(command: "services.get", data: result, pretty: parsed.pretty)
      case .operation(let operation):
        let result = try await client.getOperation(operation)
        return success(command: "operations.get", data: result, pretty: parsed.pretty)
      }
    } catch let error as GatewayError {
      return failure(error, command: command, pretty: arguments.contains("--pretty"))
    } catch is CancellationError {
      return failure(GatewayError(.cancelled, "operation cancelled"), command: command, pretty: false)
    } catch {
      return failure(GatewayError(.unexpectedError, "unexpected error"), command: command, pretty: false)
    }
  }

  private func client(for arguments: ReaderArguments, environment: [String: String]) throws -> GoogleServiceGatewayClient {
    let name = try GatewayValidation.tokenEnvironmentName(arguments.tokenEnvironment)
    guard let token = environment[name], !token.isEmpty else { throw GatewayError(.authRequired, "access token is required") }
    return GoogleServiceGatewayClient(transport: transport, tokenProvider: StaticAccessTokenProvider(token: token))
  }

  private var usage: String {
    """
    Usage: google-service-gateway-reader <services|operations> <command> [options]
      services list [--state enabled|disabled|all] [--page-size 1...200] [--page-token TOKEN] [--all-pages]
      services get --service <alias|service-id>
      operations get --operation operations/<id>
    """
  }
}

private enum ReaderCommand { case list, get(String), operation(String) }

private func readerCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 2 else { return nil }
  return switch (arguments[0], arguments[1]) {
  case ("services", "list"): "services.list"
  case ("services", "get"): "services.get"
  case ("operations", "get"): "operations.get"
  case ("services", "enable"): "services.enable"
  case ("services", "disable"): "services.disable"
  case ("services", "batch-enable"): "services.batch-enable"
  default: nil
  }
}

private struct ReaderArguments {
  let command: ReaderCommand
  let projectOption: String?
  let tokenEnvironment: String
  let pretty: Bool
  let state: ServiceListState
  let pageSize: Int
  let pageToken: String?
  let allPages: Bool

  init(_ arguments: [String], environment: [String: String]) throws {
    var index = 2
    var project: String?
    var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    var pretty = false
    var service: String?
    var operation: String?
    var state: ServiceListState = .all
    var pageSize = 50
    var pageToken: String?
    var allPages = false
    var listOptionUsed = false
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
      case "--service": service = try value()
      case "--operation": operation = try value()
      case "--state":
        guard let parsed = ServiceListState(rawValue: try value()) else { throw GatewayError(.invalidArgument, "invalid state") }
        state = parsed
        listOptionUsed = true
      case "--page-size":
        guard let parsed = Int(try value()) else { throw GatewayError(.invalidArgument, "invalid page size") }
        pageSize = parsed
        listOptionUsed = true
      case "--page-token":
        pageToken = try value()
        listOptionUsed = true
      case "--all-pages":
        allPages = true
        listOptionUsed = true
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    guard arguments.count >= 2 else { throw GatewayError(.invalidArgument, "reader command is required") }
    switch (arguments[0], arguments[1]) {
    case ("services", "list"):
      guard service == nil, operation == nil else { throw GatewayError(.invalidArgument, "service and operation options are not accepted for list") }
      if pageToken != nil, allPages { throw GatewayError(.invalidArgument, "--page-token cannot be combined with --all-pages") }
      command = .list
    case ("services", "get"):
      guard let service else { throw GatewayError(.invalidArgument, "--service is required") }
      guard operation == nil, !listOptionUsed else { throw GatewayError(.invalidArgument, "list options are not accepted for services get") }
      command = .get(service)
    case ("operations", "get"):
      guard let operation else { throw GatewayError(.invalidArgument, "--operation is required") }
      guard project == nil else { throw GatewayError(.invalidArgument, "--project is not accepted for operations get") }
      guard service == nil, !listOptionUsed else { throw GatewayError(.invalidArgument, "service and list options are not accepted for operations get") }
      command = .operation(operation)
    default: throw GatewayError(.invalidArgument, "unknown reader command")
    }
    self.projectOption = project
    self.tokenEnvironment = tokenEnvironment
    self.pretty = pretty
    self.state = state
    self.pageSize = pageSize
    self.pageToken = pageToken
    self.allPages = allPages
  }

  func project(_ environment: [String: String]) throws -> String {
    let value = projectOption ?? environment["GOOGLE_SERVICE_GATEWAY_PROJECT"] ?? environment["GOOGLE_CLOUD_PROJECT"]
    guard let value, !value.isEmpty else { throw GatewayError(.configurationError, "project is required") }
    return value
  }
}

private func success<DataValue: GatewayJSONRepresentable>(command: String, data: DataValue, pretty: Bool) -> ReaderExecution {
  let envelope: JSONValue = .object(["ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue()])
  let output = String(data: (try? GatewayJSONCodec.encode(envelope, pretty: pretty)) ?? Data("{\"ok\":true}".utf8), encoding: .utf8)!
  return ReaderExecution(output: output, isError: false, exitStatus: 0)
}

private func failure(_ error: GatewayError, command: String?, pretty: Bool) -> ReaderExecution {
  var envelope: [String: JSONValue] = ["ok": .bool(false), "error": error.gatewayJSONValue()]
  if let command { envelope["command"] = .string(command) }
  let output = String(data: (try? GatewayJSONCodec.encode(.object(envelope), pretty: pretty)) ?? Data("{\"ok\":false}".utf8), encoding: .utf8)!
  return ReaderExecution(output: output, isError: true, exitStatus: error.code.exitStatus)
}
