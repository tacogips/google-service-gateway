import Foundation
import GoogleServiceGatewayCore

public struct AuthExecution: Sendable {
  public let output: String
  public let isError: Bool
  public let exitStatus: Int32
}

public protocol InteractiveOAuthAuthorizer: Sendable {
  func authorize(
    client: OAuthClientConfiguration,
    scopes: [String],
    loginHint: String?,
    openBrowser: Bool,
    timeout: TimeInterval
  ) async throws -> (code: String, request: OAuthAuthorizationRequest)
}

public struct AuthAdapter: Sendable {
  private let vault: OAuthCredentialVault
  private let oauth: GoogleOAuthClient
  private let authorizer: any InteractiveOAuthAuthorizer

  public init(
    vault: OAuthCredentialVault = OAuthCredentialVault(),
    oauth: GoogleOAuthClient = GoogleOAuthClient(),
    authorizer: any InteractiveOAuthAuthorizer = LoopbackOAuthAuthorizer()
  ) {
    self.vault = vault
    self.oauth = oauth
    self.authorizer = authorizer
  }

  public func run(arguments: [String]) async -> AuthExecution {
    let command = authCommandName(arguments)
    if arguments.contains("--help") || arguments.contains("-h") {
      return .init(output: usage, isError: false, exitStatus: 0)
    }
    if arguments.contains("--version") {
      return .init(output: Version.current, isError: false, exitStatus: 0)
    }
    do {
      let parsed = try AuthArguments(arguments)
      switch parsed.command {
      case .clientSetup:
        return success(
          command: "clients.setup",
          data: try GoogleAuthPlatformSetup.client(project: parsed.requiredProject()),
          pretty: parsed.pretty)
      case .clientImport:
        let profile = try parsed.requiredProfile()
        let file = try parsed.requiredFile()
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: file)) } catch {
          throw GatewayError(.configurationError, "could not read OAuth client JSON")
        }
        let client = try OAuthClientConfiguration.imported(from: data)
        if let project = parsed.project {
          try validateClientProject(client, expectedProject: project)
        }
        try await vault.saveClient(client, profile: profile)
        return success(
          command: "clients.import",
          data: JSONValue.object([
            "profile": .string(profile),
            "kind": .string(client.kind.rawValue),
            "projectId": client.projectID.map(JSONValue.string) ?? .null,
            "redirectUris": .array(client.redirectURIs.map { .string($0.absoluteString) }),
          ]), pretty: parsed.pretty)
      case .clientList:
        let profiles = try await vault.profiles()
        return success(
          command: "clients.list",
          data: JSONValue.object(["profiles": .array(profiles.map { $0.gatewayJSONValue() })]),
          pretty: parsed.pretty)
      case .clientDelete:
        let profile = try parsed.requiredProfile()
        try await vault.removeProfile(profile)
        return success(
          command: "clients.delete",
          data: JSONValue.object(["profile": .string(profile), "deleted": .bool(true)]),
          pretty: parsed.pretty)
      case .consentSetup:
        let result = try GoogleAuthPlatformSetup.consent(
          project: parsed.requiredProject(), scopes: parsed.scopes)
        if let profile = parsed.profile {
          try await vault.saveScopeConfiguration(
            .init(project: result.project, scopes: result.scopes), profile: profile)
        }
        return success(
          command: "consent.setup",
          data: result, pretty: parsed.pretty)
      case .consentGet:
        let profile = try parsed.requiredProfile()
        guard let configuration = try await vault.scopeConfiguration(profile: profile) else {
          throw GatewayError(.configurationError, "OAuth scope configuration not found")
        }
        return success(command: "consent.get", data: configuration, pretty: parsed.pretty)
      case .consentDelete:
        let profile = try parsed.requiredProfile()
        try await vault.removeScopeConfiguration(profile: profile)
        return success(
          command: "consent.delete",
          data: JSONValue.object(["profile": .string(profile), "deleted": .bool(true)]),
          pretty: parsed.pretty)
      case .scopeList:
        let aliases = GoogleOAuthScopeCatalog.aliases.filter { alias, value in
          guard let service = parsed.serviceFilter?.lowercased() else { return true }
          return alias.hasPrefix(service + ".") || alias == service
            || value.contains("/auth/\(service)")
        }
        let values: [JSONValue] = aliases.sorted { $0.key < $1.key }.map {
          .object(["alias": .string($0.key), "scope": .string($0.value)])
        }
        return success(
          command: "scopes.list", data: JSONValue.object(["scopes": .array(values)]),
          pretty: parsed.pretty)
      case .login:
        let profile = try parsed.requiredProfile()
        let client = try await vault.client(profile: profile)
        let configuration = try await vault.scopeConfiguration(profile: profile)
        if let configuration {
          try validateClientProject(client, expectedProject: configuration.project)
        }
        let scopes =
          if parsed.scopes.isEmpty {
            configuration?.scopes ?? []
          } else {
            parsed.scopes
          }
        let authorization = try await authorizer.authorize(
          client: client,
          scopes: scopes,
          loginHint: parsed.loginHint,
          openBrowser: !parsed.noOpen,
          timeout: parsed.timeout
        )
        let token = try await oauth.exchange(
          code: authorization.code, request: authorization.request, client: client)
        try await vault.saveToken(token, profile: profile)
        return success(
          command: "oauth.login", data: tokenMetadata(token, profile: profile),
          pretty: parsed.pretty)
      case .refresh, .token:
        let profile = try parsed.requiredProfile()
        let client = try await vault.client(profile: profile)
        guard let stored = try await vault.token(profile: profile) else {
          throw GatewayError(.authRequired, "OAuth login is required")
        }
        let token: OAuthTokenCredential
        if parsed.command == .refresh || stored.expiresAt <= Date().addingTimeInterval(60) {
          token = try await oauth.refresh(credential: stored, client: client)
          try await vault.saveToken(token, profile: profile)
        } else {
          token = stored
        }
        return success(
          command: parsed.command == .refresh ? "oauth.refresh" : "oauth.token",
          data: OAuthTokenResult(
            accessToken: token.accessToken,
            tokenType: token.tokenType,
            scopes: token.scopes,
            expiresAt: token.expiresAt,
            refreshTokenStored: token.refreshToken != nil
          ), pretty: parsed.pretty)
      case .revoke:
        let profile = try parsed.requiredProfile()
        guard let token = try await vault.token(profile: profile) else {
          throw GatewayError(.authRequired, "OAuth login is required")
        }
        try await oauth.revoke(token)
        try await vault.removeToken(profile: profile)
        return success(
          command: "oauth.revoke",
          data: JSONValue.object(["profile": .string(profile), "revoked": .bool(true)]),
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
    Usage: google-service-gateway-auth <clients|consent|scopes|oauth> <command> [options]
      clients setup --project PROJECT
      clients import --profile NAME --file FILE [--project PROJECT]
      clients list
      clients delete --profile NAME
      consent setup --project PROJECT [--profile NAME] [--scope ALIAS-OR-URI ...]
      consent get --profile NAME
      consent delete --profile NAME
      scopes list [--service SERVICE]
      oauth login --profile NAME [--scope ALIAS-OR-URI ...] [--login-hint EMAIL] [--no-open] [--timeout SECONDS]
      oauth refresh --profile NAME
      oauth token --profile NAME
      oauth revoke --profile NAME
    """
  }
}

private enum AuthCommand: Equatable {
  case clientSetup, clientImport, clientList, clientDelete, consentSetup, consentGet, consentDelete,
    scopeList, login, refresh, token, revoke
}

private struct AuthArguments {
  let command: AuthCommand
  let project: String?
  let profile: String?
  let file: String?
  let scopes: [String]
  let serviceFilter: String?
  let loginHint: String?
  let noOpen: Bool
  let timeout: TimeInterval
  let pretty: Bool

  init(_ arguments: [String]) throws {
    guard arguments.count >= 2 else {
      throw GatewayError(.invalidArgument, "auth command is required")
    }
    command = try parseCommand(arguments[0], arguments[1])
    var project: String?
    var profile: String?
    var file: String?
    var scopes: [String] = []
    var service: String?
    var loginHint: String?
    var noOpen = false
    var timeout: TimeInterval = 300
    var pretty = false
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
      case "--profile": profile = try value()
      case "--file": file = try value()
      case "--scope": scopes.append(try value())
      case "--service": service = try value()
      case "--login-hint": loginHint = try value()
      case "--no-open": noOpen = true
      case "--timeout":
        guard let parsed = TimeInterval(try value()), parsed.isFinite, parsed > 0 else {
          throw GatewayError(.invalidArgument, "invalid timeout")
        }
        timeout = parsed
      case "--pretty": pretty = true
      default: throw GatewayError(.invalidArgument, "unknown argument")
      }
      index += 1
    }
    self.project = project
    self.profile = profile
    self.file = file
    self.scopes = scopes
    self.serviceFilter = service
    self.loginHint = loginHint
    self.noOpen = noOpen
    self.timeout = timeout
    self.pretty = pretty
    try validateOptions()
  }

  func requiredProject() throws -> String {
    guard let project else { throw GatewayError(.configurationError, "project is required") }
    return project
  }

  func requiredProfile() throws -> String {
    guard let profile else { throw GatewayError(.invalidArgument, "--profile is required") }
    return profile
  }

  func requiredFile() throws -> String {
    guard let file else { throw GatewayError(.invalidArgument, "--file is required") }
    return file
  }

  private func validateOptions() throws {
    switch command {
    case .clientSetup:
      guard project != nil, profile == nil, file == nil, scopes.isEmpty, serviceFilter == nil else {
        throw invalidOptions()
      }
    case .clientImport:
      guard profile != nil, file != nil, scopes.isEmpty, serviceFilter == nil else {
        throw invalidOptions()
      }
    case .clientList:
      guard project == nil, profile == nil, file == nil, scopes.isEmpty, serviceFilter == nil else {
        throw invalidOptions()
      }
    case .clientDelete:
      guard project == nil, profile != nil, file == nil, scopes.isEmpty, serviceFilter == nil else {
        throw invalidOptions()
      }
    case .consentSetup:
      guard project != nil, file == nil, serviceFilter == nil else {
        throw invalidOptions()
      }
    case .consentGet, .consentDelete:
      guard project == nil, profile != nil, file == nil, scopes.isEmpty, serviceFilter == nil,
        loginHint == nil, !noOpen
      else { throw invalidOptions() }
    case .scopeList:
      guard project == nil, profile == nil, file == nil, scopes.isEmpty else {
        throw invalidOptions()
      }
    case .login:
      guard project == nil, profile != nil, file == nil, serviceFilter == nil else {
        throw invalidOptions()
      }
    case .refresh, .token, .revoke:
      guard project == nil, profile != nil, file == nil, scopes.isEmpty, serviceFilter == nil,
        loginHint == nil, !noOpen
      else { throw invalidOptions() }
    }
  }

  private func invalidOptions() -> GatewayError {
    GatewayError(.invalidArgument, "options are not valid for this command")
  }
}

private func parseCommand(_ group: String, _ action: String) throws -> AuthCommand {
  switch (group, action) {
  case ("clients", "setup"): .clientSetup
  case ("clients", "import"): .clientImport
  case ("clients", "list"): .clientList
  case ("clients", "delete"): .clientDelete
  case ("consent", "setup"): .consentSetup
  case ("consent", "get"): .consentGet
  case ("consent", "delete"): .consentDelete
  case ("scopes", "list"): .scopeList
  case ("oauth", "login"): .login
  case ("oauth", "refresh"): .refresh
  case ("oauth", "token"): .token
  case ("oauth", "revoke"): .revoke
  default: throw GatewayError(.invalidArgument, "unknown auth command")
  }
}

private func authCommandName(_ arguments: [String]) -> String? {
  guard arguments.count >= 2 else { return nil }
  return "\(arguments[0]).\(arguments[1])"
}

private func tokenMetadata(_ token: OAuthTokenCredential, profile: String) -> JSONValue {
  .object([
    "profile": .string(profile),
    "scopes": .array(token.scopes.map(JSONValue.string)),
    "expiresAt": .string(ISO8601DateFormatter().string(from: token.expiresAt)),
    "refreshTokenStored": .bool(token.refreshToken != nil),
  ])
}

private func validateClientProject(
  _ client: OAuthClientConfiguration,
  expectedProject: String
) throws {
  let expected = String(
    try GatewayValidation.project(expectedProject).dropFirst("projects/".count))
  guard client.projectID == expected else {
    throw GatewayError(
      .configurationError,
      "OAuth client project does not match the configured project"
    )
  }
}

private func success<DataValue: GatewayJSONRepresentable>(
  command: String, data: DataValue, pretty: Bool
) -> AuthExecution {
  let envelope: JSONValue = .object([
    "ok": .bool(true), "command": .string(command), "data": data.gatewayJSONValue(),
  ])
  let output =
    String(
      data: (try? GatewayJSONCodec.encode(envelope, pretty: pretty)) ?? Data("{\"ok\":true}".utf8),
      encoding: .utf8) ?? "{\"ok\":true}"
  return AuthExecution(output: output, isError: false, exitStatus: 0)
}

private func failure(_ error: GatewayError, command: String?, pretty: Bool) -> AuthExecution {
  var envelope: [String: JSONValue] = ["ok": .bool(false), "error": error.gatewayJSONValue()]
  if let command { envelope["command"] = .string(command) }
  let output =
    String(
      data: (try? GatewayJSONCodec.encode(.object(envelope), pretty: pretty))
        ?? Data("{\"ok\":false}".utf8), encoding: .utf8) ?? "{\"ok\":false}"
  return AuthExecution(output: output, isError: true, exitStatus: error.code.exitStatus)
}
