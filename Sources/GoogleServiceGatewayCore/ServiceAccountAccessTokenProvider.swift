import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public protocol ServiceAccountJWTSigner: Sendable {
  func signSHA256RSA(message: Data, privateKeyPEM: String) throws -> Data
}

private struct ServiceAccountCredential: Decodable {
  let type: String
  let clientEmail: String
  let privateKey: String
  let tokenURI: String

  enum CodingKeys: String, CodingKey {
    case type
    case clientEmail = "client_email"
    case privateKey = "private_key"
    case tokenURI = "token_uri"
  }
}

public struct OpenSSLServiceAccountJWTSigner: ServiceAccountJWTSigner {
  public init() {}

  public func signSHA256RSA(message: Data, privateKeyPEM: String) throws -> Data {
    var template = Array("/tmp/google-service-gateway-key.XXXXXX\0".utf8CString)
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
      mkstemp(buffer.baseAddress!)
    }
    guard descriptor >= 0 else {
      throw GatewayError(.configurationError, "could not create a private signing file")
    }
    guard
      let path = String(
        bytes: template.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), encoding: .utf8)
    else { throw GatewayError(.configurationError, "could not resolve the private signing file") }
    defer {
      close(descriptor)
      _ = unlink(path)
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw GatewayError(.configurationError, "could not secure the private signing file")
    }
    let keyBytes = Array(privateKeyPEM.utf8)
    var offset = 0
    while offset < keyBytes.count {
      let written = keyBytes.withUnsafeBytes { bytes in
        write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
      }
      guard written > 0 else {
        throw GatewayError(.configurationError, "could not prepare the private signing key")
      }
      offset += written
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = ["dgst", "-sha256", "-sign", path]
    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = diagnostics
    do {
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: message)
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
    } catch {
      throw GatewayError(.configurationError, "OpenSSL signing could not be started")
    }
    guard process.terminationStatus == 0 else {
      throw GatewayError(.configurationError, "OpenSSL could not sign the service-account assertion")
    }
    return try output.fileHandleForReading.readToEnd() ?? Data()
  }
}

public actor ServiceAccountAccessTokenProvider: AccessTokenProvider {
  private let credential: ServiceAccountCredential
  private let transport: any GatewayHTTPTransport
  private let signer: any ServiceAccountJWTSigner
  private let clock: any GatewayWallClock
  private let scopes: [String]
  private var cachedToken: (value: String, expiresAt: Date)?

  public init(
    credentialJSON: String,
    scopes: [String] = ["https://www.googleapis.com/auth/cloud-platform"],
    transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
    signer: any ServiceAccountJWTSigner = OpenSSLServiceAccountJWTSigner(),
    clock: any GatewayWallClock = SystemGatewayWallClock()
  ) throws {
    let parsed: ServiceAccountCredential
    do {
      parsed = try JSONDecoder().decode(
        ServiceAccountCredential.self, from: Data(credentialJSON.utf8))
    } catch {
      throw GatewayError(.configurationError, "service-account credential JSON is invalid")
    }
    guard parsed.type == "service_account",
      parsed.tokenURI == "https://oauth2.googleapis.com/token",
      parsed.clientEmail.contains("@"),
      parsed.privateKey.hasPrefix("-----BEGIN PRIVATE KEY-----"),
      !scopes.isEmpty,
      scopes.allSatisfy({ $0.hasPrefix("https://www.googleapis.com/auth/") })
    else {
      throw GatewayError(.configurationError, "service-account credential JSON is unsupported")
    }
    self.credential = parsed
    self.transport = transport
    self.signer = signer
    self.clock = clock
    self.scopes = scopes
  }

  public func accessToken() async throws -> String {
    let now = clock.now()
    if let cachedToken, cachedToken.expiresAt > now.addingTimeInterval(60) {
      return cachedToken.value
    }
    let issuedAt = Int(now.timeIntervalSince1970)
    let header = try base64URL(
      JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"]))
    let claims = try base64URL(
      JSONSerialization.data(withJSONObject: [
        "iss": credential.clientEmail,
        "scope": scopes.joined(separator: " "),
        "aud": credential.tokenURI,
        "iat": issuedAt,
        "exp": issuedAt + 3600
      ]))
    let unsigned = "\(header).\(claims)"
    let signature = try signer.signSHA256RSA(
      message: Data(unsigned.utf8), privateKeyPEM: credential.privateKey)
    let assertion = "\(unsigned).\(base64URL(signature))"
    let body = formEncode([
      ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
      ("assertion", assertion)
    ])
    let response = try await transport.send(
      GatewayHTTPRequest(
        method: "POST", url: URL(string: credential.tokenURI)!,
        headers: ["Content-Type": "application/x-www-form-urlencoded"],
        body: Data(body.utf8)))
    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError(
        response.statusCode == 401 ? .authenticationFailed : .providerError,
        "service-account token exchange failed", httpStatus: response.statusCode)
    }
    guard case .object(let object) = try GatewayJSONCodec.decode(response.body),
      case .string(let token) = object["access_token"], !token.isEmpty,
      case .number(let expiry) = object["expires_in"], let expiresIn = TimeInterval(expiry),
      expiresIn > 0,
      object["token_type"] == .string("Bearer")
    else {
      throw GatewayError(.malformedResponse, "service-account token response is invalid")
    }
    cachedToken = (token, now.addingTimeInterval(expiresIn))
    return token
  }
}

private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func formEncode(_ values: [(String, String)]) -> String {
  let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
  return values.map { key, value in
    "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
  }.joined(separator: "&")
}
