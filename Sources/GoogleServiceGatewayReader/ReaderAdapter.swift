import Foundation
import GoogleServiceGatewayCore

public struct ReaderExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public struct ReaderAdapter: Sendable {
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
  ) async -> ReaderExecution {
    let command = readerCommandName(arguments)
    if arguments.contains("--help") || arguments.contains("-h") {
      return .init(output: usage, isError: false, exitStatus: 0)
    }
    if arguments.contains("--version") {
      return .init(output: Version.current, isError: false, exitStatus: 0)
    }
    guard arguments.count >= 2,
      ["services", "operations", "api-keys", "billing", "iam"].contains(arguments[0])
    else {
      return failure(
        GatewayError(.invalidArgument, "unknown reader command"), command: command, pretty: false)
    }
    if arguments[0] == "services", ["enable", "disable", "batch-enable"].contains(arguments[1]) {
      return failure(
        GatewayError(.invalidArgument, "reader does not support mutations"), command: command,
        pretty: false)
    }
    do {
      let parsed = try ReaderArguments(arguments, environment: environment)
      let tokenProvider = try tokenProvider(for: parsed, environment: environment)
      switch parsed.command {
      case .list:
        let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: tokenProvider)
        let result = try await client.listServices(
          .init(
            project: try parsed.project(environment), state: parsed.state,
            pageSize: parsed.pageSize, pageToken: parsed.pageToken, allPages: parsed.allPages))
        return success(command: "services.list", data: result, pretty: parsed.pretty)
      case .get(let service):
        let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: tokenProvider)
        let result = try await client.getService(
          project: try parsed.project(environment), service: service)
        return success(command: "services.get", data: result, pretty: parsed.pretty)
      case .operation(let operation):
        let client = GoogleServiceGatewayClient(transport: transport, tokenProvider: tokenProvider)
        let result = try await client.getOperation(operation)
        return success(command: "operations.get", data: result, pretty: parsed.pretty)
      case .apiKeyList:
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: tokenProvider)
        return success(
          command: "api-keys.list",
          data: try await client.list(
            project: try parsed.project(environment), pageSize: parsed.pageSize,
            pageToken: parsed.pageToken), pretty: parsed.pretty)
      case .apiKeyGet(let key):
        let client = GoogleAPIKeysClient(transport: transport, tokenProvider: tokenProvider)
        return success(
          command: "api-keys.get", data: try await client.get(key), pretty: parsed.pretty)
      case .billingAccountList:
        let client = GoogleCloudBillingClient(transport: transport, tokenProvider: tokenProvider)
        return success(
          command: "billing.accounts.list",
          data: try await client.listAccounts(
            pageSize: parsed.pageSize, pageToken: parsed.pageToken), pretty: parsed.pretty)
      case .billingAccountGet(let account):
        let client = GoogleCloudBillingClient(transport: transport, tokenProvider: tokenProvider)
        return success(
          command: "billing.accounts.get", data: try await client.getAccount(account),
          pretty: parsed.pretty)
      case .billingProjectGet:
        let client = GoogleCloudBillingClient(transport: transport, tokenProvider: tokenProvider)
        return success(
          command: "billing.projects.get",
          data: try await client.getProjectBilling(try parsed.project(environment)),
          pretty: parsed.pretty)
      case .iamPermissionsTest(let permissions):
        let client = GoogleProjectIAMClient(transport: transport, tokenProvider: tokenProvider)
        return success(
          command: "iam.permissions.test",
          data: try await client.testPermissions(
            project: try parsed.project(environment), permissions: permissions),
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

  private func tokenProvider(for arguments: ReaderArguments, environment: [String: String]) throws
    -> any AccessTokenProvider {
    if let profile = arguments.oauthProfile {
      return RefreshingOAuthAccessTokenProvider(profile: profile, vault: vault)
    }
    if let environmentName = arguments.serviceAccountEnvironment {
      let name = try GatewayValidation.tokenEnvironmentName(environmentName)
      guard let credential = environment[name], !credential.isEmpty else {
        throw GatewayError(.authRequired, "service-account credential JSON is required")
      }
      return try ServiceAccountAccessTokenProvider(
        credentialJSON: credential, transport: transport, signer: serviceAccountSigner)
    }
    let name = try GatewayValidation.tokenEnvironmentName(arguments.tokenEnvironment)
    guard let token = environment[name], !token.isEmpty else {
      throw GatewayError(.authRequired, "access token is required")
    }
    return StaticAccessTokenProvider(token: token)
  }

  private var usage: String {
    """
    Usage: google-service-gateway-reader <services|operations|api-keys|billing|iam> <command> [options]
      services list [--state enabled|disabled|all] [--page-size 1...200] [--page-token TOKEN] [--all-pages]
      services get --service <alias|service-id>
      operations get --operation operations/<id>
      api-keys list --project PROJECT [--page-size 1...200] [--page-token TOKEN]
      api-keys get --key projects/PROJECT/locations/global/keys/KEY
      billing accounts list [--page-size 1...100] [--page-token TOKEN]
      billing accounts get --billing-account billingAccounts/ACCOUNT
      billing projects get --project PROJECT
      iam permissions test --project PROJECT --permission IAM_PERMISSION [--permission IAM_PERMISSION ...]
    Authentication: --oauth-profile NAME, --service-account-env NAME, or --access-token-env NAME
    """
  }
}

private enum ReaderCommand {
  case list
  case get(String)
  case operation(String)
  case apiKeyList
  case apiKeyGet(String)
  case billingAccountList
  case billingAccountGet(String)
  case billingProjectGet
  case iamPermissionsTest([String])
}

private func readerCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 2 else { return nil }
  return switch (arguments[0], arguments[1]) {
  case ("services", "list"): "services.list"
  case ("services", "get"): "services.get"
  case ("operations", "get"): "operations.get"
  case ("api-keys", "list"): "api-keys.list"
  case ("api-keys", "get"): "api-keys.get"
  case ("billing", "accounts"): arguments.count >= 3 ? "billing.accounts.\(arguments[2])" : nil
  case ("billing", "projects"): arguments.count >= 3 ? "billing.projects.\(arguments[2])" : nil
  case ("iam", "permissions"): arguments.count >= 3 ? "iam.permissions.\(arguments[2])" : nil
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
  let oauthProfile: String?
  let serviceAccountEnvironment: String?
  let pretty: Bool
  let state: ServiceListState
  let pageSize: Int
  let pageToken: String?
  let allPages: Bool

  init(_ arguments: [String], environment: [String: String]) throws {
    if arguments.first == "billing" {
      let billing = try BillingReaderArguments(arguments)
      command = billing.command
      projectOption = billing.project
      tokenEnvironment = billing.tokenEnvironment
      oauthProfile = billing.oauthProfile
      serviceAccountEnvironment = billing.serviceAccountEnvironment
      pretty = billing.pretty
      state = .all
      pageSize = billing.pageSize
      pageToken = billing.pageToken
      allPages = false
      return
    }
    var index = arguments.first == "iam" ? 3 : 2
    var project: String?
    var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    var tokenEnvironmentSpecified = false
    var oauthProfile: String?
    var serviceAccountEnvironment: String?
    var pretty = false
    var service: String?
    var operation: String?
    var key: String?
    var state: ServiceListState = .all
    var pageSize = 50
    var pageToken: String?
    var allPages = false
    var permissions: [String] = []
    var listOptionUsed = false
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
      case "--service-account-env": serviceAccountEnvironment = try value()
      case "--permission": permissions.append(try value())
      case "--pretty": pretty = true
      case "--service": service = try value()
      case "--operation": operation = try value()
      case "--key": key = try value()
      case "--state":
        guard let parsed = ServiceListState(rawValue: try value()) else {
          throw GatewayError(.invalidArgument, "invalid state")
        }
        state = parsed
        listOptionUsed = true
      case "--page-size":
        guard let parsed = Int(try value()) else {
          throw GatewayError(.invalidArgument, "invalid page size")
        }
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
    guard arguments.count >= 2 else {
      throw GatewayError(.invalidArgument, "reader command is required")
    }
    command = try standardReaderCommand(
      arguments: arguments, project: project, service: service, operation: operation, key: key,
      state: state, pageToken: pageToken, allPages: allPages, listOptionUsed: listOptionUsed,
      permissions: permissions)
    self.projectOption = project
    guard [tokenEnvironmentSpecified, oauthProfile != nil, serviceAccountEnvironment != nil]
      .filter({ $0 }).count <= 1
    else {
      throw GatewayError(
        .invalidArgument, "authentication options cannot be combined")
    }
    self.tokenEnvironment = tokenEnvironment
    self.oauthProfile = oauthProfile
    self.serviceAccountEnvironment = serviceAccountEnvironment
    self.pretty = pretty
    self.state = state
    self.pageSize = pageSize
    self.pageToken = pageToken
    self.allPages = allPages
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

private func standardReaderCommand(
  arguments: [String], project: String?, service: String?, operation: String?, key: String?,
  state: ServiceListState, pageToken: String?, allPages: Bool, listOptionUsed: Bool,
  permissions: [String]
) throws -> ReaderCommand {
  if arguments.first != "iam", !permissions.isEmpty {
    throw GatewayError(.invalidArgument, "--permission is only accepted for IAM permission test")
  }
  switch (arguments[0], arguments[1]) {
  case ("services", "list"):
    guard service == nil, operation == nil, key == nil else {
      throw GatewayError(.invalidArgument, "resource options are not accepted for list")
    }
    guard pageToken == nil || !allPages else {
      throw GatewayError(.invalidArgument, "--page-token cannot be combined with --all-pages")
    }
    return .list
  case ("services", "get"):
    guard let service else { throw GatewayError(.invalidArgument, "--service is required") }
    guard operation == nil, key == nil, !listOptionUsed else {
      throw GatewayError(.invalidArgument, "list options are not accepted for services get")
    }
    return .get(service)
  case ("operations", "get"):
    guard let operation else { throw GatewayError(.invalidArgument, "--operation is required") }
    guard project == nil else {
      throw GatewayError(.invalidArgument, "--project is not accepted for operations get")
    }
    guard service == nil, key == nil, !listOptionUsed else {
      throw GatewayError(
        .invalidArgument, "resource and list options are not accepted for operations get")
    }
    return .operation(operation)
  case ("api-keys", "list"):
    guard service == nil, operation == nil, key == nil, state == .all, !allPages else {
      throw GatewayError(.invalidArgument, "unsupported option for api-keys list")
    }
    return .apiKeyList
  case ("api-keys", "get"):
    guard let key else { throw GatewayError(.invalidArgument, "--key is required") }
    guard project == nil, service == nil, operation == nil, !listOptionUsed else {
      throw GatewayError(.invalidArgument, "unsupported option for api-keys get")
    }
    return .apiKeyGet(key)
  case ("iam", "permissions") where arguments.count >= 3 && arguments[2] == "test":
    guard service == nil, operation == nil, key == nil, !listOptionUsed else {
      throw GatewayError(.invalidArgument, "unsupported option for IAM permission test")
    }
    return .iamPermissionsTest(try GatewayValidation.iamPermissions(permissions))
  default: throw GatewayError(.invalidArgument, "unknown reader command")
  }
}

private struct BillingReaderArguments {
  let command: ReaderCommand
  let project: String?
  let tokenEnvironment: String
  let oauthProfile: String?
  let serviceAccountEnvironment: String?
  let pretty: Bool
  let pageSize: Int
  let pageToken: String?

  init(_ arguments: [String]) throws {
    guard arguments.count >= 3 else {
      throw GatewayError(.invalidArgument, "billing reader command is required")
    }
    var project: String?
    var account: String?
    var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    var tokenEnvironmentSpecified = false
    var oauthProfile: String?
    var serviceAccountEnvironment: String?
    var pretty = false
    var pageSize = 50
    var pageToken: String?
    var index = 3
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
      case "--billing-account": account = try value()
      case "--access-token-env":
        tokenEnvironment = try value()
        tokenEnvironmentSpecified = true
      case "--oauth-profile": oauthProfile = try value()
      case "--service-account-env": serviceAccountEnvironment = try value()
      case "--pretty": pretty = true
      case "--page-size":
        guard let parsed = Int(try value()) else {
          throw GatewayError(.invalidArgument, "invalid page size")
        }
        pageSize = parsed
      case "--page-token": pageToken = try value()
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    switch (arguments[1], arguments[2]) {
    case ("accounts", "list"):
      guard project == nil, account == nil else { throw invalidBillingReaderOptions() }
      command = .billingAccountList
    case ("accounts", "get"):
      guard project == nil, let account, pageSize == 50, pageToken == nil else {
        throw invalidBillingReaderOptions()
      }
      command = .billingAccountGet(account)
    case ("projects", "get"):
      guard project != nil, account == nil, pageSize == 50, pageToken == nil else {
        throw invalidBillingReaderOptions()
      }
      command = .billingProjectGet
    default: throw GatewayError(.invalidArgument, "unknown reader command")
    }
    guard [tokenEnvironmentSpecified, oauthProfile != nil, serviceAccountEnvironment != nil]
      .filter({ $0 }).count <= 1
    else {
      throw GatewayError(
        .invalidArgument, "authentication options cannot be combined")
    }
    self.project = project
    self.tokenEnvironment = tokenEnvironment
    self.oauthProfile = oauthProfile
    self.serviceAccountEnvironment = serviceAccountEnvironment
    self.pretty = pretty
    self.pageSize = try GatewayValidation.billingPageSize(pageSize)
    self.pageToken = try GatewayValidation.pageToken(pageToken)
  }
}

private func invalidBillingReaderOptions() -> GatewayError {
  GatewayError(.invalidArgument, "unsupported option for billing reader command")
}

private func success<DataValue: GatewayJSONRepresentable>(
  command: String, data: DataValue, pretty: Bool
) -> ReaderExecution {
  let envelope: JSONValue = .object([
    "ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue()
  ])
  let encoded = (try? GatewayJSONCodec.encode(envelope, pretty: pretty))
    ?? Data("{\"ok\":true}".utf8)
  let output = String(bytes: encoded, encoding: .utf8) ?? "{\"ok\":true}"
  return ReaderExecution(output: output, isError: false, exitStatus: 0)
}

private func failure(_ error: GatewayError, command: String?, pretty: Bool) -> ReaderExecution {
  var envelope: [String: JSONValue] = ["ok": .bool(false), "error": error.gatewayJSONValue()]
  if let command { envelope["command"] = .string(command) }
  let encoded = (try? GatewayJSONCodec.encode(.object(envelope), pretty: pretty))
    ?? Data("{\"ok\":false}".utf8)
  let output = String(bytes: encoded, encoding: .utf8) ?? "{\"ok\":false}"
  return ReaderExecution(output: output, isError: true, exitStatus: error.code.exitStatus)
}
