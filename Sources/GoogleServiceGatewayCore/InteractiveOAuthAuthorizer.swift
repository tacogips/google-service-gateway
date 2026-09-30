import Foundation

public protocol InteractiveOAuthAuthorizer: Sendable {
  func authorize(
    client: OAuthClientConfiguration,
    scopes: [String],
    loginHint: String?,
    openBrowser: Bool,
    timeout: TimeInterval
  ) async throws -> (code: String, request: OAuthAuthorizationRequest)
}

