import Foundation

public struct GatewayHTTPRequest: Sendable {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data?

  public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct GatewayHTTPResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

public protocol GatewayHTTPTransport: Sendable {
  func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse
}

public struct URLSessionGatewayTransport: GatewayHTTPTransport {
  public init() {}

  public func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    do {
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      guard let response = response as? HTTPURLResponse else {
        throw GatewayError(.unexpectedError, "non-HTTP response")
      }
      let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
        if let name = entry.key as? String, let value = entry.value as? String {
          result[name] = value
        }
      }
      return GatewayHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    } catch let error as GatewayError {
      throw error
    } catch {
      throw GatewayError(.providerError, "transport request failed")
    }
  }
}

public protocol AccessTokenProvider: Sendable {
  func accessToken() async throws -> String
}

public struct StaticAccessTokenProvider: AccessTokenProvider {
  private let token: String

  public init(token: String) { self.token = token }
  public func accessToken() async throws -> String {
    guard !token.isEmpty else { throw GatewayError(.authRequired, "access token is required") }
    return token
  }
}

public protocol GatewaySleeper: Sendable {
  func sleep(for seconds: TimeInterval) async throws
}

public struct TaskGatewaySleeper: GatewaySleeper {
  public init() {}
  public func sleep(for seconds: TimeInterval) async throws {
    try await Task.sleep(for: .seconds(seconds))
  }
}

public protocol GatewayClock: Sendable {
  func now() -> TimeInterval
}

public struct SystemGatewayClock: GatewayClock {
  public init() {}
  public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
