import Foundation
import GoogleServiceGatewayCore

public struct AdminExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public struct AdminAdapter: Sendable {
  private let transport: any GatewayHTTPTransport
  private let vault: OAuthCredentialVault
  private let clock: any GatewayWallClock
  private let nonceProvider: any GatewayNonceProvider
  private let replayStore: (any AdminPlanReplayStore)?
  private let serviceAccountSigner: any ServiceAccountJWTSigner

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    vault: OAuthCredentialVault = OAuthCredentialVault(),
    clock: any GatewayWallClock = SystemGatewayWallClock(),
    nonceProvider: any GatewayNonceProvider = UUIDGatewayNonceProvider(),
    replayStore: (any AdminPlanReplayStore)? = nil,
    serviceAccountSigner: any ServiceAccountJWTSigner = OpenSSLServiceAccountJWTSigner()
  ) {
    self.transport = transport
    self.vault = vault
    self.clock = clock
    self.nonceProvider = nonceProvider
    self.replayStore = replayStore
    self.serviceAccountSigner = serviceAccountSigner
  }

  public func run(
    arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> AdminExecution {
    let command = adminCommandName(arguments)
    if arguments.contains("--help") || arguments.contains("-h") {
      return .init(output: usage, isError: false, exitStatus: 0)
    }
    if arguments.contains("--version") {
      return .init(output: Version.current, isError: false, exitStatus: 0)
    }
    do {
      let parsed = try AdminArguments(arguments)
      let keyName = try GatewayValidation.tokenEnvironmentName(parsed.planKeyEnvironment)
      guard let keyValue = environment[keyName], keyValue.utf8.count >= 32 else {
        throw GatewayError(.configurationError, "admin plan signing key is required")
      }
      let provider = try tokenProvider(parsed, environment: environment)
      let client = GoogleCloudBillingClient(transport: transport, tokenProvider: provider)
      let admin = GoogleCloudBillingAdmin(
        billing: client, clock: clock, nonceProvider: nonceProvider)
      switch parsed.action {
      case .plan:
        let plan = try await admin.plan(
          operation: parsed.operation, project: try parsed.requiredProject(),
          billingAccount: parsed.billingAccount,
          credentialSelector: parsed.credentialSelector,
          signingKey: Data(keyValue.utf8), lifetime: parsed.expiresIn)
        return success(command: parsed.operation.rawValue, data: plan, pretty: parsed.pretty)
      case .apply:
        let plan = try BillingAdminPlan.decode(try securePlanData(path: parsed.requiredPlanPath()))
        try parsed.validateConfirmations(plan)
        let store: any AdminPlanReplayStore
        if let replayStore {
          store = replayStore
        } else {
          store = try FileAdminPlanReplayStore(path: parsed.requiredStateDirectory())
        }
        let result = try await admin.apply(
          plan, expectedOperation: parsed.operation,
          credentialSelector: parsed.credentialSelector,
          signingKey: Data(keyValue.utf8), replayStore: store)
        return success(command: parsed.operation.rawValue, data: result, pretty: parsed.pretty)
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

  private func tokenProvider(_ parsed: AdminArguments, environment: [String: String]) throws
    -> any AccessTokenProvider {
    if let profile = parsed.oauthProfile {
      return RefreshingOAuthAccessTokenProvider(profile: profile, vault: vault)
    }
    if let environmentName = parsed.serviceAccountEnvironment {
      let name = try GatewayValidation.tokenEnvironmentName(environmentName)
      guard let credential = environment[name], !credential.isEmpty else {
        throw GatewayError(.authRequired, "service-account credential JSON is required")
      }
      return try ServiceAccountAccessTokenProvider(
        credentialJSON: credential, transport: transport, signer: serviceAccountSigner)
    }
    let name = try GatewayValidation.tokenEnvironmentName(parsed.tokenEnvironment)
    guard let token = environment[name], !token.isEmpty else {
      throw GatewayError(.authRequired, "access token is required")
    }
    return StaticAccessTokenProvider(token: token)
  }

  private var usage: String {
    """
    Usage: google-service-gateway-admin billing projects <link|unlink> <plan|apply> [options]
      link plan --project PROJECT --billing-account ACCOUNT [--expires-in 60...3600]
      link apply --plan FILE --confirm-project projects/PROJECT --confirm-billing-account ACCOUNT
      unlink plan --project PROJECT [--expires-in 60...3600]
      unlink apply --plan FILE --confirm-project projects/PROJECT --confirm-billing-account ACCOUNT --confirm-unlink
    Apply requires --state-dir ABSOLUTE_PATH unless a replay store is injected.
    Authentication: --oauth-profile NAME, --service-account-env NAME, or --access-token-env NAME
    Plan signing: --plan-key-env NAME (default GOOGLE_SERVICE_GATEWAY_ADMIN_PLAN_KEY)
    """
  }
}

private enum AdminAction { case plan, apply }

private struct AdminArguments {
  let operation: BillingAdminOperation
  let action: AdminAction
  var project: String?
  var billingAccount: String?
  var planPath: String?
  var stateDirectory: String?
  var confirmProject: String?
  var confirmBillingAccount: String?
  var confirmUnlink = false
  var expiresIn: TimeInterval = 600
  var tokenEnvironment = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
  var oauthProfile: String?
  var serviceAccountEnvironment: String?
  var tokenEnvironmentSpecified = false
  var planKeyEnvironment = "GOOGLE_SERVICE_GATEWAY_ADMIN_PLAN_KEY"
  var pretty = false

  init(_ arguments: [String]) throws {
    guard arguments.count >= 4, arguments[0] == "billing", arguments[1] == "projects",
      let operation = BillingAdminOperation(
        rawValue: "billing.projects.\(arguments[2])")
    else { throw GatewayError(.invalidArgument, "unknown admin command") }
    self.operation = operation
    switch arguments[3] {
    case "plan": action = .plan
    case "apply": action = .apply
    default: throw GatewayError(.invalidArgument, "unknown admin command")
    }
    var index = 4
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
      case "--billing-account": billingAccount = try value()
      case "--plan": planPath = try value()
      case "--state-dir": stateDirectory = try value()
      case "--confirm-project": confirmProject = try value()
      case "--confirm-billing-account": confirmBillingAccount = try value()
      case "--confirm-unlink": confirmUnlink = true
      case "--expires-in":
        guard let parsed = TimeInterval(try value()) else {
          throw GatewayError(.invalidArgument, "invalid plan lifetime")
        }
        expiresIn = parsed
      case "--access-token-env":
        tokenEnvironment = try value()
        tokenEnvironmentSpecified = true
      case "--oauth-profile": oauthProfile = try value()
      case "--service-account-env": serviceAccountEnvironment = try value()
      case "--plan-key-env": planKeyEnvironment = try value()
      case "--pretty": pretty = true
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    try validateOptions()
  }

  var credentialSelector: String {
    if let oauthProfile { return "oauth-profile:\(oauthProfile)" }
    if let serviceAccountEnvironment { return "service-account-env:\(serviceAccountEnvironment)" }
    return "access-token-env:\(tokenEnvironment)"
  }

  func requiredProject() throws -> String {
    guard let project else { throw GatewayError(.invalidArgument, "--project is required") }
    return project
  }

  func requiredPlanPath() throws -> String {
    guard let planPath else { throw GatewayError(.invalidArgument, "--plan is required") }
    return planPath
  }

  func requiredStateDirectory() throws -> String {
    guard let stateDirectory else {
      throw GatewayError(.configurationError, "--state-dir is required for apply")
    }
    return stateDirectory
  }

  func validateConfirmations(_ plan: BillingAdminPlan) throws {
    guard confirmProject == plan.project,
      confirmBillingAccount == (operation == .link
        ? plan.desiredBillingAccount : plan.currentBilling.billingAccount),
      operation == .link || confirmUnlink
    else { throw GatewayError(.invalidArgument, "exact billing confirmations are required") }
  }

  private func validateOptions() throws {
    guard [tokenEnvironmentSpecified, oauthProfile != nil, serviceAccountEnvironment != nil]
      .filter({ $0 }).count <= 1
    else {
      throw GatewayError(
        .invalidArgument, "authentication options cannot be combined")
    }
    switch action {
    case .plan:
      guard project != nil, planPath == nil, stateDirectory == nil,
        confirmProject == nil, confirmBillingAccount == nil, !confirmUnlink,
        operation == .link ? billingAccount != nil : billingAccount == nil
      else { throw GatewayError(.invalidArgument, "invalid options for admin plan") }
    case .apply:
      guard project == nil, billingAccount == nil, planPath != nil,
        confirmProject != nil, confirmBillingAccount != nil,
        expiresIn == 600
      else { throw GatewayError(.invalidArgument, "invalid options for admin apply") }
    }
  }
}

private func adminCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 3, arguments[0] == "billing", arguments[1] == "projects" else {
    return nil
  }
  return "billing.projects.\(arguments[2])"
}

private func securePlanData(path: String) throws -> Data {
  let url = URL(fileURLWithPath: path)
  let values = try url.resourceValues(forKeys: [
    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
  ])
  guard values.isRegularFile == true, values.isSymbolicLink != true,
    let size = values.fileSize, size <= 1_048_576
  else { throw GatewayError(.invalidArgument, "plan must be a bounded regular file") }
  return try Data(contentsOf: url, options: [.mappedIfSafe])
}

private func success<Value: GatewayJSONRepresentable>(
  command: String, data: Value, pretty: Bool
) -> AdminExecution {
  let envelope: JSONValue = .object([
    "ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue()
  ])
  let encoded = (try? GatewayJSONCodec.encode(envelope, pretty: pretty))
    ?? Data("{\"ok\":true}".utf8)
  return AdminExecution(
    output: String(bytes: encoded, encoding: .utf8) ?? "{\"ok\":true}",
    isError: false, exitStatus: 0)
}

private func failure(_ error: GatewayError, command: String?, pretty: Bool) -> AdminExecution {
  var envelope: [String: JSONValue] = ["ok": .bool(false), "error": error.gatewayJSONValue()]
  if let command { envelope["command"] = .string(command) }
  let encoded = (try? GatewayJSONCodec.encode(.object(envelope), pretty: pretty))
    ?? Data("{\"ok\":false}".utf8)
  return AdminExecution(
    output: String(bytes: encoded, encoding: .utf8) ?? "{\"ok\":false}",
    isError: true, exitStatus: error.code.exitStatus)
}
