import Foundation
import GoogleGatewayAuth
import Testing
@testable import GoogleServiceGatewayCore

@Test func webClientRequiresExactRegisteredRedirect() throws {
  let redirect = try #require(URL(string: "https://gateway.example.com/oauth/callback"))
  let client = OAuthClientConfiguration(kind: .web, clientID: "fixture.apps.googleusercontent.com",
    clientSecret: "fixture", redirectURIs: [redirect])
  let request = try GoogleOAuthClient().authorizationRequest(client: client, redirectURI: redirect, scopes: ["cloud-platform"])
  let query = URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
  #expect(query?.first(where: { $0.name == "redirect_uri" })?.value == redirect.absoluteString)
  #expect(query?.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
  #expect(throws: GatewayError.self) {
    try GoogleOAuthClient().authorizationRequest(client: client,
      redirectURI: #require(URL(string: "https://gateway.example.com/other")), scopes: ["cloud-platform"])
  }
}

@Test func configuredCallbackTimeoutKeepsNativeErrorContract() async throws {
  let settings = try OAuthCallbackSettings(prefix: "TEST_", environment: [:])
  let client = OAuthClientConfiguration(kind: .installed, clientID: "fixture.apps.googleusercontent.com",
    redirectURIs: [try #require(URL(string: "http://localhost"))])
  let authorizer = LoopbackOAuthAuthorizer(presenter: { _, _ in }, callbackSettings: settings)
  do {
    _ = try await authorizer.authorize(client: client, scopes: ["cloud-platform"], loginHint: nil, openBrowser: false, timeout: 0.01)
    Issue.record("Expected a callback timeout")
  } catch let error as GatewayError {
    #expect(error.code == .operationTimeout)
  }
}
