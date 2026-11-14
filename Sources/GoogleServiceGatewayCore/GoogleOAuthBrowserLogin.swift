import Foundation

/// Runs desktop browser authorization and returns a refreshable user credential.
/// The caller supplies its registered application client and persists the result
/// in its existing credential store after all grant checks succeed.
public struct GoogleOAuthBrowserLogin: Sendable {
  private let oauth: GoogleOAuthClient
  private let authorizer: any InteractiveOAuthAuthorizer

  public init(
    oauth: GoogleOAuthClient = GoogleOAuthClient(),
    authorizer: any InteractiveOAuthAuthorizer = LoopbackOAuthAuthorizer()
  ) {
    self.oauth = oauth
    self.authorizer = authorizer
  }

  public func login(
    client: OAuthClientConfiguration,
    scopes: [String],
    loginHint: String? = nil,
    openBrowser: Bool = true,
    timeout: TimeInterval = 300
  ) async throws -> OAuthTokenCredential {
    try Task.checkCancellation()
    try validateOAuthBrowserLogin(client: client, timeout: timeout)
    let requestedScopes = try GoogleOAuthScopeCatalog.resolve(scopes)
    let authorization = try await authorizer.authorize(
      client: client,
      scopes: requestedScopes,
      loginHint: loginHint,
      openBrowser: openBrowser,
      timeout: timeout
    )
    try Task.checkCancellation()
    guard Set(authorization.request.requestedScopes) == Set(requestedScopes) else {
      throw GatewayError(.authenticationFailed, "OAuth authorization did not use the requested scopes")
    }
    let token = try await oauth.exchange(
      code: authorization.code, request: authorization.request, client: client
    )
    try Task.checkCancellation()
    guard Set(requestedScopes).isSubset(of: Set(token.scopes)) else {
      throw GatewayError(.authenticationFailed, "OAuth authorization did not grant all requested scopes")
    }
    guard let refreshToken = token.refreshToken, !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GatewayError(.authenticationFailed, "OAuth authorization did not return a refresh token; authorize again")
    }
    return token
  }
}

func validateOAuthBrowserLogin(client: OAuthClientConfiguration, timeout: TimeInterval) throws {
  guard !client.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw GatewayError(.configurationError, "Browser login requires a registered OAuth application")
  }
  if client.kind == .web, client.clientSecret?.isEmpty != false {
    throw GatewayError(.configurationError, "Web OAuth login requires a client secret")
  }
  guard timeout.isFinite, timeout > 0, timeout <= 3_600 else {
    throw GatewayError(.invalidArgument, "OAuth login timeout must be between 0 and 3600 seconds")
  }
}
