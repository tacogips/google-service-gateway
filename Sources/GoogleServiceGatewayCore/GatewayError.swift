import Foundation

public enum GatewayErrorCode: String, Codable, Sendable {
  case unexpectedError = "UNEXPECTED_ERROR"
  case cancelled = "CANCELLED"
  case invalidArgument = "INVALID_ARGUMENT"
  case configurationError = "CONFIGURATION_ERROR"
  case authRequired = "AUTH_REQUIRED"
  case authenticationFailed = "AUTHENTICATION_FAILED"
  case permissionDenied = "PERMISSION_DENIED"
  case notFound = "NOT_FOUND"
  case failedPrecondition = "FAILED_PRECONDITION"
  case rateLimited = "RATE_LIMITED"
  case providerError = "PROVIDER_ERROR"
  case malformedResponse = "MALFORMED_RESPONSE"
  case operationFailed = "OPERATION_FAILED"
  case operationTimeout = "OPERATION_TIMEOUT"

  public var exitStatus: Int32 {
    switch self {
    case .unexpectedError, .cancelled: 1
    case .invalidArgument: 2
    case .configurationError, .authRequired: 3
    case .authenticationFailed, .permissionDenied, .notFound, .failedPrecondition, .rateLimited, .providerError, .malformedResponse: 4
    case .operationFailed: 5
    case .operationTimeout: 6
    }
  }
}

public struct GatewayError: Error, Equatable, Sendable, LocalizedError {
  public let code: GatewayErrorCode
  public let message: String
  public let httpStatus: Int?
  public let googleCode: Int?
  public let googleStatus: String?
  public let operationName: String?
  public let details: [JSONValue]?

  public init(_ code: GatewayErrorCode, _ message: String, httpStatus: Int? = nil, googleCode: Int? = nil, googleStatus: String? = nil, operationName: String? = nil, details: [JSONValue]? = nil) {
    self.code = code
    self.message = message
    self.httpStatus = httpStatus
    self.googleCode = googleCode
    self.googleStatus = googleStatus
    self.operationName = operationName
    self.details = details
  }

  public var errorDescription: String? { message }
}

extension GatewayError: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var object: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
    if let httpStatus { object["httpStatus"] = .number(String(httpStatus)) }
    if let googleCode { object["googleCode"] = .number(String(googleCode)) }
    if let googleStatus { object["googleStatus"] = .string(googleStatus) }
    if let operationName { object["operationName"] = .string(operationName) }
    if let details { object["details"] = .array(details) }
    return .object(object)
  }
}

public enum Redactor {
  public static func redact(_ value: JSONValue, token: String = "") -> JSONValue {
    switch value {
    case .object(let object):
      var redacted = [String: JSONValue]()
      for (key, nested) in object.sorted(by: { $0.key < $1.key }) {
        let safeKey = scrub(key, token: token)
        let uniqueKey = collisionSafeKey(safeKey, existingKeys: redacted.keys)
        redacted[uniqueKey] = isSensitive(key) ? .string("<redacted>") : redact(nested, token: token)
      }
      return .object(redacted)
    case .array(let values): return .array(values.map { redact($0, token: token) })
    case .string(let value): return .string(scrub(value, token: token))
    default: return value
    }
  }

  public static func scrub(_ value: String, token: String) -> String {
    token.isEmpty ? value : value.replacingOccurrences(of: token, with: "<redacted>")
  }

  public static func redact(_ error: GatewayError, token: String) -> GatewayError {
    GatewayError(
      error.code,
      scrub(error.message, token: token),
      httpStatus: error.httpStatus,
      googleCode: error.googleCode,
      googleStatus: error.googleStatus.map { scrub($0, token: token) },
      operationName: error.operationName.map { scrub($0, token: token) },
      details: error.details.map { details in
        details.map { redact($0, token: token) }
      }
    )
  }

  private static func isSensitive(_ key: String) -> Bool {
    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
    return ["authorization", "token", "credential", "secret"].contains { normalized.contains($0) }
  }

  private static func collisionSafeKey(
    _ key: String,
    existingKeys: Dictionary<String, JSONValue>.Keys
  ) -> String {
    guard existingKeys.contains(key) else { return key }
    var suffix = 2
    while existingKeys.contains("\(key)#\(suffix)") { suffix += 1 }
    return "\(key)#\(suffix)"
  }
}
