#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
import Foundation

public struct LoopbackOAuthAuthorizer: InteractiveOAuthAuthorizer {
  private let oauth: GoogleOAuthClient
  private let presenter: @Sendable (URL, Bool) async throws -> Void

  public init(oauth: GoogleOAuthClient = GoogleOAuthClient()) {
    self.oauth = oauth
    presenter = Self.presentAuthorizationURL
  }

  public init(
    oauth: GoogleOAuthClient = GoogleOAuthClient(),
    presenter: @escaping @Sendable (URL, Bool) async throws -> Void
  ) {
    self.oauth = oauth
    self.presenter = presenter
  }

  public func authorize(
    client: OAuthClientConfiguration,
    scopes: [String],
    loginHint: String?,
    openBrowser: Bool,
    timeout: TimeInterval
  ) async throws -> (code: String, request: OAuthAuthorizationRequest) {
    try validateOAuthBrowserLogin(client: client, timeout: timeout)
    let server = try LoopbackHTTPServer()
    let request = try oauth.authorizationRequest(
      client: client,
      redirectURI: server.redirectURI,
      scopes: scopes,
      loginHint: loginHint
    )
    try await presenter(request.authorizationURL, openBrowser)
    let callback = try await server.wait(timeout: timeout)
    if let error = callback.error {
      throw GatewayError(.authenticationFailed, "OAuth authorization failed: \(error)")
    }
    guard callback.state == request.state else {
      throw GatewayError(.authenticationFailed, "OAuth state validation failed")
    }
    guard let code = callback.code, !code.isEmpty else {
      throw GatewayError(
        .authenticationFailed, "OAuth callback did not contain an authorization code")
    }
    return (code, request)
  }

  private static func presentAuthorizationURL(_ url: URL, openBrowser: Bool) async throws {
    if openBrowser {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = [url.absoluteString]
      do { try process.run() } catch {
        throw GatewayError(.configurationError, "could not open the authorization URL")
      }
    } else {
      FileHandle.standardError.write(Data((url.absoluteString + "\n").utf8))
    }
  }
}

private struct OAuthCallback: Sendable {
  let code: String?
  let state: String?
  let error: String?
}

private final class LoopbackHTTPServer: @unchecked Sendable {
  private let descriptor: Int32
  let redirectURI: URL

  init() throws {
    #if canImport(Darwin)
      let streamSocketType = SOCK_STREAM
    #else
      let streamSocketType = Int32(SOCK_STREAM.rawValue)
    #endif
    let descriptor = socket(AF_INET, streamSocketType, 0)
    guard descriptor >= 0 else {
      throw GatewayError(.configurationError, "could not create OAuth callback listener")
    }
    var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    #if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(descriptor, 1) == 0 else {
      close(descriptor)
      throw GatewayError(.configurationError, "could not bind OAuth callback listener")
    }
    var local = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &local) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard named == 0,
      let redirect = URL(
        string: "http://127.0.0.1:\(UInt16(bigEndian: local.sin_port))/oauth/callback")
    else {
      close(descriptor)
      throw GatewayError(.configurationError, "could not determine OAuth callback port")
    }
    self.descriptor = descriptor
    redirectURI = redirect
  }

  deinit { close(descriptor) }

  func wait(timeout: TimeInterval) async throws -> OAuthCallback {
    let descriptor = descriptor
    return try await Task.detached {
      let deadline = ProcessInfo.processInfo.systemUptime + timeout
      try waitForCallbackData(descriptor: descriptor, deadline: deadline)
      let connection = accept(descriptor, nil, nil)
      guard connection >= 0 else {
        throw GatewayError(.providerError, "OAuth callback could not be accepted")
      }
      defer { close(connection) }
      let request = try readCallbackRequest(connection: connection, deadline: deadline)
      guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else {
        throw GatewayError(.malformedResponse, "OAuth callback request was malformed")
      }
      let parts = firstLine.split(separator: " ")
      guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
        let components = URLComponents(string: "http://127.0.0.1\(parts[1])")
      else {
        throw GatewayError(.malformedResponse, "OAuth callback request was malformed")
      }
      guard components.path == "/oauth/callback" else {
        throw GatewayError(.malformedResponse, "OAuth callback path was invalid")
      }
      var query: [String: String] = [:]
      for item in components.queryItems ?? [] {
        guard query[item.name] == nil else {
          throw GatewayError(.malformedResponse, "OAuth callback contained duplicate parameters")
        }
        query[item.name] = item.value ?? ""
      }
      let html =
        "<html><body><h1>Authorization received</h1><p>You can close this window.</p></body></html>"
      let response =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
      #if canImport(Darwin)
        var suppressPipeSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &suppressPipeSignal, socklen_t(MemoryLayout<Int32>.size))
        let sendFlags: Int32 = 0
      #else
        let sendFlags = Int32(MSG_NOSIGNAL)
      #endif
      _ = response.withCString { send(connection, $0, strlen($0), sendFlags) }
      return OAuthCallback(code: query["code"], state: query["state"], error: query["error"])
    }.value
  }
}

private func waitForCallbackData(descriptor: Int32, deadline: TimeInterval) throws {
  let remaining = deadline - ProcessInfo.processInfo.systemUptime
  guard remaining > 0 else {
    throw GatewayError(.operationTimeout, "OAuth callback timed out")
  }
  var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
  let milliseconds = Int32(min(ceil(remaining * 1_000), Double(Int32.max)))
  guard poll(&item, 1, milliseconds) > 0 else {
    throw GatewayError(.operationTimeout, "OAuth callback timed out")
  }
}

private func readCallbackRequest(connection: Int32, deadline: TimeInterval) throws -> String {
  var request = Data()
  let maximumBytes = 16_384
  while request.count < maximumBytes {
    try waitForCallbackData(descriptor: connection, deadline: deadline)
    var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes - request.count))
    let count = recv(connection, &buffer, buffer.count, 0)
    guard count > 0 else {
      throw GatewayError(.malformedResponse, "OAuth callback request was incomplete")
    }
    request.append(contentsOf: buffer[..<count])
    if request.range(of: Data("\r\n\r\n".utf8)) != nil {
      guard let text = String(data: request, encoding: .utf8) else {
        throw GatewayError(.malformedResponse, "OAuth callback request was malformed")
      }
      return text
    }
  }
  throw GatewayError(.malformedResponse, "OAuth callback request was too large")
}
