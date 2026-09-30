import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Resolves externally obtained credentials without modifying the credential vault.
public enum GoogleServiceExternalCredentials {
  public static func tokenProvider(
    environment: [String: String], profile: String? = nil,
    tokenEnvironment: String = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN",
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    signer: any ServiceAccountJWTSigner = OpenSSLServiceAccountJWTSigner()
  ) throws -> (any AccessTokenProvider)? {
    let prefix: String
    if let profile {
      let normalized = profile.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
      prefix = "GOOGLE_SERVICE_GATEWAY_CREDENTIAL_" + String(normalized) + "_"
    } else { prefix = "GOOGLE_SERVICE_GATEWAY_" }
    let suffixes = ["ACCESS_TOKEN", "TOKEN_STORE_JSON", "TOKEN_STORE_PATH", "SERVICE_ACCOUNT_JSON", "SERVICE_ACCOUNT_PATH"]
    let selected = suffixes.compactMap { suffix -> (String, String)? in
      guard let value = nonBlank(environment[prefix + suffix]) else { return nil }
      return (suffix, value)
    }
    let alias = profile == nil ? nonBlank(environment[try GatewayValidation.tokenEnvironmentName(tokenEnvironment)]) : nil
    if let alias, let canonical = selected.first(where: { $0.0 == "ACCESS_TOKEN" }), alias != canonical.1 {
      throw GatewayError(.configurationError, "Conflicting access-token environment variables")
    }
    guard selected.count <= 1, !(alias != nil && selected.contains(where: { $0.0 != "ACCESS_TOKEN" })) else {
      throw GatewayError(.configurationError, "Select one external credential source")
    }
    guard let entry = selected.first else {
      if let alias { return try directToken(alias) }
      return nil
    }
    switch entry.0 {
    case "ACCESS_TOKEN": return try directToken(entry.1)
    case "TOKEN_STORE_JSON", "TOKEN_STORE_PATH":
      let data = try credentialData(entry.1, isPath: entry.0 == "TOKEN_STORE_PATH")
      let token: OAuthTokenCredential
      do {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(OAuthTokenCredential.self, from: data) { token = decoded } else { token = try JSONDecoder().decode(OAuthTokenCredential.self, from: data) }
      } catch { throw GatewayError(.configurationError, "External token store is invalid") }
      guard token.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
            token.expiresAt > Date().addingTimeInterval(60) else {
        throw GatewayError(.authRequired, "External token is expired or invalid; supply replacement credentials")
      }
      return try directToken(token.accessToken)
    default:
      let data = try credentialData(entry.1, isPath: entry.0 == "SERVICE_ACCOUNT_PATH")
      guard let json = String(data: data, encoding: .utf8) else {
        throw GatewayError(.configurationError, "Service-account JSON must be UTF-8")
      }
      return try ServiceAccountAccessTokenProvider(credentialJSON: json, transport: transport, signer: signer)
    }
  }

  public static func oauthClient(
    environment: [String: String], profile: String
  ) throws -> OAuthClientConfiguration? {
    let normalized = profile.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
    let specific = "GOOGLE_SERVICE_GATEWAY_CREDENTIAL_" + String(normalized) + "_"
    let hasSpecific = nonBlank(environment[specific + "OAUTH_CLIENT_JSON"]) != nil || nonBlank(environment[specific + "OAUTH_CLIENT_PATH"]) != nil
    let prefix = hasSpecific ? specific : "GOOGLE_SERVICE_GATEWAY_"
    let json = nonBlank(environment[prefix + "OAUTH_CLIENT_JSON"])
    let path = nonBlank(environment[prefix + "OAUTH_CLIENT_PATH"])
    guard json == nil || path == nil else {
      throw GatewayError(.configurationError, "Select OAuth client JSON or path")
    }
    guard let value = json ?? path else { return nil }
    return try OAuthClientConfiguration.imported(from: credentialData(value, isPath: json == nil))
  }

  private static func directToken(_ value: String) throws -> StaticAccessTokenProvider {
    guard value.utf8.count <= 8192, !value.utf8.contains(where: { $0 < 33 || $0 == 127 }) else {
      throw GatewayError(.configurationError, "Access token contains unsupported characters")
    }
    return StaticAccessTokenProvider(token: value)
  }

  private static func credentialData(_ value: String, isPath: Bool) throws -> Data {
    let maximumBytes = 1_048_576
    if !isPath {
      guard value.utf8.count <= maximumBytes else { throw GatewayError(.configurationError, "Credential JSON is too large") }
      return Data(value.utf8)
    }
    let descriptor = value.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw GatewayError(.configurationError, "Credential file is unavailable") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
      throw GatewayError(.configurationError, "Credential file must be a private regular file owned by the current user")
    }
    let data: Data
    do { data = try handle.read(upToCount: maximumBytes + 1) ?? Data() } catch { throw GatewayError(.configurationError, "Credential file could not be read") }
    guard data.count <= maximumBytes else { throw GatewayError(.configurationError, "Credential file is too large") }
    return data
  }

  private static func nonBlank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
