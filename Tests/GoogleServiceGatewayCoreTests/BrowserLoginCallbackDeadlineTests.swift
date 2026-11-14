import Foundation
import Testing
@testable import GoogleServiceGatewayCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Test func sharedBrowserCallbackBoundsIncompleteHTTPRequests() async throws {
  let connection = IncompleteCallbackConnection()
  let authorizer = LoopbackOAuthAuthorizer { authorizationURL, _ in
    let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let redirect = try #require(items.first { $0.name == "redirect_uri" }?.value)
    try await connection.open(redirect: redirect)
  }
  // Also bound the test on the old implementation: closing the peer produces
  // an incomplete-request error rather than leaving a permanently blocked recv.
  let delayedClose = Task {
    try? await Task.sleep(for: .seconds(1))
    if !Task.isCancelled { await connection.closeConnection() }
  }
  let client = OAuthClientConfiguration(
    kind: .installed, clientID: "test-client", redirectURIs: []
  )
  var failure: GatewayError?
  do {
    _ = try await authorizer.authorize(
      client: client, scopes: ["calendar.readonly"], loginHint: nil, openBrowser: false, timeout: 0.05
    )
    Issue.record("Incomplete callback request was accepted")
  } catch let error as GatewayError {
    failure = error
  } catch {
    delayedClose.cancel()
    await connection.closeConnection()
    throw error
  }
  delayedClose.cancel()
  await connection.closeConnection()
  #expect(failure?.code == .operationTimeout)
}

private actor IncompleteCallbackConnection {
  private var descriptor: Int32?

  func open(redirect: String) throws {
    let url = try #require(URLComponents(string: redirect))
    let port = try #require(url.port)
    #if canImport(Darwin)
    let socketType = SOCK_STREAM
    #else
    let socketType = Int32(SOCK_STREAM.rawValue)
    #endif
    let socketDescriptor = socket(AF_INET, socketType, 0)
    guard socketDescriptor >= 0 else { throw GatewayError(.unexpectedError, "Test socket could not be created") }
    descriptor = socketDescriptor
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { throw GatewayError(.unexpectedError, "Test callback could not connect") }
    let partial = "GET /oauth/callback HTTP/1.1\r\n"
    _ = partial.withCString { send(socketDescriptor, $0, strlen($0), 0) }
  }

  func closeConnection() {
    if let descriptor {
      close(descriptor)
      self.descriptor = nil
    }
  }
}
