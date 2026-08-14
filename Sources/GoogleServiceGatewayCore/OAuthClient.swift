import CryptoKit
import Foundation

public struct GoogleOAuthClient: Sendable {
  private let transport: any GatewayHTTPTransport
  private let now: @Sendable () -> Date
  private let revokeEndpoint: URL

  public init(
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    revokeEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.transport = transport
    self.revokeEndpoint = revokeEndpoint
    self.now = now
  }

  public func authorizationRequest(
    client: OAuthClientConfiguration,
    redirectURI: URL,
    scopes inputScopes: [String],
    loginHint: String? = nil,
    promptConsent: Bool = true
  ) throws -> OAuthAuthorizationRequest {
    guard redirectURI.scheme == "http",
      ["127.0.0.1", "localhost", "::1"].contains(redirectURI.host ?? "")
    else {
      throw GatewayError(.invalidArgument, "OAuth redirect URI must use an HTTP loopback host")
    }
    let scopes = try GoogleOAuthScopeCatalog.resolve(inputScopes)
    let verifier = randomURLSafeString(byteCount: 48)
    let state = randomURLSafeString(byteCount: 32)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    var components = URLComponents(
      url: client.authorizationEndpoint, resolvingAgainstBaseURL: false)
    var query = [
      URLQueryItem(name: "client_id", value: client.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "include_granted_scopes", value: "true"),
    ]
    if promptConsent { query.append(URLQueryItem(name: "prompt", value: "consent")) }
    if let loginHint, !loginHint.isEmpty {
      query.append(URLQueryItem(name: "login_hint", value: loginHint))
    }
    components?.queryItems = query
    guard let url = components?.url else {
      throw GatewayError(.unexpectedError, "could not construct authorization URL")
    }
    return OAuthAuthorizationRequest(
      authorizationURL: url,
      redirectURI: redirectURI,
      state: state,
      codeVerifier: verifier,
      requestedScopes: scopes
    )
  }

  public func exchange(
    code: String,
    request: OAuthAuthorizationRequest,
    client: OAuthClientConfiguration
  ) async throws -> OAuthTokenCredential {
    guard !code.isEmpty else {
      throw GatewayError(.invalidArgument, "authorization code is required")
    }
    var fields = [
      "client_id": client.clientID,
      "code": code,
      "code_verifier": request.codeVerifier,
      "grant_type": "authorization_code",
      "redirect_uri": request.redirectURI.absoluteString,
    ]
    if let secret = client.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
    return try await tokenRequest(
      endpoint: client.tokenEndpoint,
      fields: fields,
      fallbackScopes: request.requestedScopes,
      previousRefreshToken: nil,
      secrets: [code, request.codeVerifier, client.clientSecret].compactMap { $0 }
    )
  }

  public func refresh(
    credential: OAuthTokenCredential,
    client: OAuthClientConfiguration
  ) async throws -> OAuthTokenCredential {
    guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
      throw GatewayError(.authRequired, "stored OAuth credential has no refresh token")
    }
    var fields = [
      "client_id": client.clientID,
      "refresh_token": refreshToken,
      "grant_type": "refresh_token",
    ]
    if let secret = client.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
    return try await tokenRequest(
      endpoint: client.tokenEndpoint,
      fields: fields,
      fallbackScopes: credential.scopes,
      previousRefreshToken: refreshToken,
      secrets: [refreshToken, client.clientSecret].compactMap { $0 }
    )
  }

  public func revoke(_ credential: OAuthTokenCredential) async throws {
    let token = credential.refreshToken ?? credential.accessToken
    let body = formEncoded(["token": token])
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(
        .init(
          method: "POST",
          url: revokeEndpoint,
          headers: [
            "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json",
          ],
          body: body
        ))
    } catch let error as GatewayError {
      throw Redactor.redact(error, token: token)
    } catch {
      throw GatewayError(.providerError, "OAuth revocation request failed")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw oauthError(response, secrets: [token])
    }
  }

  private func tokenRequest(
    endpoint: URL,
    fields: [String: String],
    fallbackScopes: [String],
    previousRefreshToken: String?,
    secrets: [String]
  ) async throws -> OAuthTokenCredential {
    let response: GatewayHTTPResponse
    do {
      response = try await transport.send(
        .init(
          method: "POST",
          url: endpoint,
          headers: [
            "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json",
          ],
          body: formEncoded(fields)
        ))
    } catch let error as GatewayError {
      throw secrets.reduce(error) { Redactor.redact($0, token: $1) }
    } catch {
      throw GatewayError(.providerError, "OAuth token request failed")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw oauthError(response, secrets: secrets)
    }
    do {
      let object = try oauthObject(GatewayJSONCodec.decode(response.body))
      let accessToken = try oauthRequiredString(object, "access_token")
      let tokenType = try oauthOptionalString(object["token_type"]) ?? "Bearer"
      let expiresIn = try oauthNumber(object["expires_in"]) ?? 3600
      guard expiresIn > 0 else {
        throw GatewayError(.malformedResponse, "OAuth token response has invalid expiry")
      }
      let scopeString = try oauthOptionalString(object["scope"])
      let scopes = scopeString?.split(separator: " ").map(String.init) ?? fallbackScopes
      let refresh = try oauthOptionalString(object["refresh_token"]) ?? previousRefreshToken
      let refreshExpiresIn = try oauthNumber(object["refresh_token_expires_in"])
      return OAuthTokenCredential(
        accessToken: accessToken,
        refreshToken: refresh,
        tokenType: tokenType,
        scopes: scopes,
        expiresAt: now().addingTimeInterval(expiresIn),
        refreshTokenExpiresAt: refreshExpiresIn.map { now().addingTimeInterval($0) }
      )
    } catch let error as GatewayError {
      throw secrets.reduce(error) { Redactor.redact($0, token: $1) }
    } catch {
      throw GatewayError(
        .malformedResponse, "OAuth token response could not be decoded",
        httpStatus: response.statusCode)
    }
  }
}

public struct RefreshingOAuthAccessTokenProvider: AccessTokenProvider {
  private let profile: String
  private let vault: OAuthCredentialVault
  private let client: GoogleOAuthClient
  private let refreshLeeway: TimeInterval
  private let now: @Sendable () -> Date

  public init(
    profile: String,
    vault: OAuthCredentialVault = OAuthCredentialVault(),
    client: GoogleOAuthClient = GoogleOAuthClient(),
    refreshLeeway: TimeInterval = 60,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.profile = profile
    self.vault = vault
    self.client = client
    self.refreshLeeway = refreshLeeway
    self.now = now
  }

  public func accessToken() async throws -> String {
    guard var token = try await vault.token(profile: profile) else {
      throw GatewayError(.authRequired, "OAuth login is required")
    }
    if token.expiresAt <= now().addingTimeInterval(refreshLeeway) {
      token = try await client.refresh(
        credential: token, client: try await vault.client(profile: profile))
      try await vault.saveToken(token, profile: profile)
    }
    return token.accessToken
  }
}

public enum GoogleAuthPlatformSetup {
  public static func client(project inputProject: String) throws -> OAuthSetupResult {
    let project = try GatewayValidation.project(inputProject)
    let id = String(project.dropFirst("projects/".count))
    var components = URLComponents(string: "https://console.cloud.google.com/auth/clients")
    components?.queryItems = [URLQueryItem(name: "project", value: id)]
    guard let url = components?.url else {
      throw GatewayError(.unexpectedError, "could not construct Console URL")
    }
    return OAuthSetupResult(
      project: project,
      consoleURL: url,
      automated: false,
      reason:
        "Google exposes no supported public API for general OAuth client creation; create a Desktop client in Google Auth Platform and import its JSON."
    )
  }

  public static func consent(project inputProject: String, scopes inputScopes: [String]) throws
    -> ConsentSetupResult
  {
    let project = try GatewayValidation.project(inputProject)
    let id = String(project.dropFirst("projects/".count))
    let scopes = try GoogleOAuthScopeCatalog.resolve(inputScopes)
    var components = URLComponents(string: "https://console.cloud.google.com/auth/overview")
    components?.queryItems = [URLQueryItem(name: "project", value: id)]
    guard let url = components?.url else {
      throw GatewayError(.unexpectedError, "could not construct Console URL")
    }
    return ConsentSetupResult(project: project, consoleURL: url, scopes: scopes, automated: false)
  }
}

private func formEncoded(_ fields: [String: String]) -> Data {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
  let string = fields.sorted { $0.key < $1.key }.map { key, value in
    let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    return "\(encodedKey)=\(encodedValue)"
  }.joined(separator: "&")
  return Data(string.utf8)
}

private func oauthObject(_ value: JSONValue?) throws -> [String: JSONValue] {
  guard case .object(let object) = value else {
    throw GatewayError(.malformedResponse, "OAuth response could not be decoded")
  }
  return object
}

private func oauthRequiredString(_ object: [String: JSONValue], _ key: String) throws -> String {
  guard case .string(let value) = object[key], !value.isEmpty else {
    throw GatewayError(.malformedResponse, "OAuth response is missing \(key)")
  }
  return value
}

private func oauthOptionalString(_ value: JSONValue?) throws -> String? {
  guard let value else { return nil }
  guard case .string(let string) = value else {
    throw GatewayError(.malformedResponse, "OAuth response could not be decoded")
  }
  return string
}

private func oauthNumber(_ value: JSONValue?) throws -> TimeInterval? {
  guard let value else { return nil }
  guard case .number(let raw) = value, let number = TimeInterval(raw), number.isFinite else {
    throw GatewayError(.malformedResponse, "OAuth response contains an invalid number")
  }
  return number
}

private func oauthError(_ response: GatewayHTTPResponse, secrets: [String]) -> GatewayError {
  let value = try? GatewayJSONCodec.decode(response.body)
  let object = try? oauthObject(value)
  let error = (try? oauthOptionalString(object?["error"])) ?? "oauth_error"
  let description =
    (try? oauthOptionalString(object?["error_description"])) ?? "OAuth provider request failed"
  let safe = secrets.reduce("\(error): \(description)") { Redactor.scrub($0, token: $1) }
  let code: GatewayErrorCode = response.statusCode == 401 ? .authenticationFailed : .providerError
  return GatewayError(code, safe, httpStatus: response.statusCode)
}

private func randomURLSafeString(byteCount: Int) -> String {
  var generator = SystemRandomNumberGenerator()
  let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  return Data(bytes).base64URLEncodedString()
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
