import Foundation

public indirect enum JSONValue: Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(String)
  case bool(Bool)
  case null

}

public protocol GatewayJSONRepresentable: Sendable {
  func gatewayJSONValue() -> JSONValue
}

extension JSONValue: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue { self }
}

public enum GatewayJSONCodec {
  public static func decode(_ data: Data) throws -> JSONValue {
    var parser = Parser(bytes: Array(data))
    return try parser.parseDocument()
  }

  public static func encode(_ value: JSONValue, pretty: Bool = false) throws -> Data {
    var writer = Writer(pretty: pretty)
    try writer.write(value)
    return Data(writer.output.utf8)
  }

  public static func encode<Value: GatewayJSONRepresentable>(_ value: Value, pretty: Bool = false) throws -> Data {
    try encode(value.gatewayJSONValue(), pretty: pretty)
  }

  private struct Writer {
    let pretty: Bool
    var output = ""

    mutating func write(_ value: JSONValue, depth: Int = 0) throws {
      switch value {
      case .object(let object):
        let entries = object.sorted { $0.key < $1.key }
        guard !entries.isEmpty else { output += "{}"; return }
        output += "{"
        if pretty { output += "\n" }
        for (index, entry) in entries.enumerated() {
          if pretty { output += String(repeating: "  ", count: depth + 1) }
          try writeString(entry.key)
          output += pretty ? ": " : ":"
          try write(entry.value, depth: depth + 1)
          if index < entries.count - 1 { output += "," }
          if pretty { output += "\n" }
        }
        if pretty { output += String(repeating: "  ", count: depth) }
        output += "}"
      case .array(let values):
        guard !values.isEmpty else { output += "[]"; return }
        output += "["
        if pretty { output += "\n" }
        for (index, nested) in values.enumerated() {
          if pretty { output += String(repeating: "  ", count: depth + 1) }
          try write(nested, depth: depth + 1)
          if index < values.count - 1 { output += "," }
          if pretty { output += "\n" }
        }
        if pretty { output += String(repeating: "  ", count: depth) }
        output += "]"
      case .string(let value):
        try writeString(value)
      case .number(let value):
        guard (try? GatewayJSONCodec.decode(Data(value.utf8))) == .number(value) else {
          throw GatewayError(.invalidArgument, "invalid JSON number")
        }
        output += value
      case .bool(let value):
        output += value ? "true" : "false"
      case .null:
        output += "null"
      }
    }

    mutating func writeString(_ value: String) throws {
      let encoded = try JSONEncoder().encode(value)
      output += String(decoding: encoded, as: UTF8.self)
    }
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func parseDocument() throws -> JSONValue {
      skipWhitespace()
      let value = try parseValue()
      skipWhitespace()
      guard index == bytes.count else { throw malformed() }
      return value
    }

    mutating func parseValue() throws -> JSONValue {
      skipWhitespace()
      guard index < bytes.count else { throw malformed() }
      switch bytes[index] {
      case 123: return try parseObject()
      case 91: return try parseArray()
      case 34: return .string(try parseString())
      case 116: return try parseLiteral("true", value: .bool(true))
      case 102: return try parseLiteral("false", value: .bool(false))
      case 110: return try parseLiteral("null", value: .null)
      case 45, 48...57: return try parseNumber()
      default: throw malformed()
      }
    }

    mutating func parseObject() throws -> JSONValue {
      index += 1
      skipWhitespace()
      var object = [String: JSONValue]()
      if consume(125) { return .object(object) }
      while true {
        guard peek() == 34 else { throw malformed() }
        let key = try parseString()
        guard object[key] == nil else { throw malformed() }
        skipWhitespace()
        guard consume(58) else { throw malformed() }
        object[key] = try parseValue()
        skipWhitespace()
        if consume(125) { return .object(object) }
        guard consume(44) else { throw malformed() }
        skipWhitespace()
      }
    }

    mutating func parseArray() throws -> JSONValue {
      index += 1
      skipWhitespace()
      var values = [JSONValue]()
      if consume(93) { return .array(values) }
      while true {
        values.append(try parseValue())
        skipWhitespace()
        if consume(93) { return .array(values) }
        guard consume(44) else { throw malformed() }
      }
    }

    mutating func parseString() throws -> String {
      guard consume(34) else { throw malformed() }
      var output = ""
      var utf8 = [UInt8]()
      func flush() throws {
        if !utf8.isEmpty {
          guard let string = String(bytes: utf8, encoding: .utf8) else { throw malformed() }
          output += string
          utf8.removeAll(keepingCapacity: true)
        }
      }
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 34 {
          try flush()
          return output
        }
        if byte == 92 {
          try flush()
          guard index < bytes.count else { throw malformed() }
          let escape = bytes[index]
          index += 1
          switch escape {
          case 34: output.append("\"")
          case 92: output.append("\\")
          case 47: output.append("/")
          case 98: output.append("\u{08}")
          case 102: output.append("\u{0C}")
          case 110: output.append("\n")
          case 114: output.append("\r")
          case 116: output.append("\t")
          case 117: output.unicodeScalars.append(try parseUnicodeScalar())
          default: throw malformed()
          }
        } else {
          guard byte >= 32 else { throw malformed() }
          utf8.append(byte)
        }
      }
      throw malformed()
    }

    mutating func parseUnicodeScalar() throws -> UnicodeScalar {
      let first = try parseUnicodeCodeUnit()
      if (0xD800...0xDBFF).contains(first) {
        guard consume(92), consume(117) else { throw malformed() }
        let second = try parseUnicodeCodeUnit()
        guard (0xDC00...0xDFFF).contains(second) else { throw malformed() }
        let value = 0x10000 + (Int(first - 0xD800) << 10) + Int(second - 0xDC00)
        guard let scalar = UnicodeScalar(value) else { throw malformed() }
        return scalar
      }
      guard !(0xDC00...0xDFFF).contains(first), let scalar = UnicodeScalar(first) else { throw malformed() }
      return scalar
    }

    mutating func parseUnicodeCodeUnit() throws -> UInt16 {
      guard index + 4 <= bytes.count else { throw malformed() }
      var value: UInt16 = 0
      for byte in bytes[index..<(index + 4)] {
        let digit: UInt16
        switch byte {
        case 48...57: digit = UInt16(byte - 48)
        case 65...70: digit = UInt16(byte - 65 + 10)
        case 97...102: digit = UInt16(byte - 97 + 10)
        default: throw malformed()
        }
        value = value * 16 + digit
      }
      index += 4
      return value
    }

    mutating func parseLiteral(_ literal: String, value: JSONValue) throws -> JSONValue {
      let expected = Array(literal.utf8)
      guard bytes[index...].starts(with: expected) else { throw malformed() }
      index += expected.count
      return value
    }

    mutating func parseNumber() throws -> JSONValue {
      let start = index
      _ = consume(45)
      guard index < bytes.count else { throw malformed() }
      if consume(48) {
        guard peek().map({ $0 < 48 || $0 > 57 }) ?? true else { throw malformed() }
      } else {
        guard peek().map({ $0 >= 49 && $0 <= 57 }) == true else { throw malformed() }
        repeat { index += 1 } while peek().map({ $0 >= 48 && $0 <= 57 }) == true
      }
      if consume(46) {
        guard peek().map({ $0 >= 48 && $0 <= 57 }) == true else { throw malformed() }
        repeat { index += 1 } while peek().map({ $0 >= 48 && $0 <= 57 }) == true
      }
      if peek() == 69 || peek() == 101 {
        index += 1
        _ = consume(43) || consume(45)
        guard peek().map({ $0 >= 48 && $0 <= 57 }) == true else { throw malformed() }
        repeat { index += 1 } while peek().map({ $0 >= 48 && $0 <= 57 }) == true
      }
      return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating func skipWhitespace() {
      while peek().map({ $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }) == true { index += 1 }
    }

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
    mutating func consume(_ byte: UInt8) -> Bool {
      guard peek() == byte else { return false }
      index += 1
      return true
    }
    func malformed() -> GatewayError { GatewayError(.malformedResponse, "provider response could not be decoded") }
  }
}

public enum ServiceState: String, Codable, CaseIterable, Sendable {
  case enabled = "ENABLED"
  case disabled = "DISABLED"
  case unspecified = "STATE_UNSPECIFIED"
}

public enum ServiceListState: String, Codable, Sendable {
  case enabled
  case disabled
  case all

  var providerFilter: String? {
    switch self {
    case .enabled: "state:ENABLED"
    case .disabled: "state:DISABLED"
    case .all: nil
    }
  }
}

public struct GatewayService: Equatable, Sendable {
  public let name: String
  public let parent: String
  public let serviceId: String
  public let state: ServiceState
  public let config: JSONValue

  public init(name: String, parent: String, serviceId: String, state: ServiceState, config: JSONValue = .object([:])) {
    self.name = name
    self.parent = parent
    self.serviceId = serviceId
    self.state = state
    self.config = config
  }
}

public struct GatewayOperationError: Equatable, Sendable {
  public let code: Int
  public let message: String
  public let details: [JSONValue]?
}

public struct GatewayOperation: Equatable, Sendable {
  public let name: String
  public let done: Bool
  public let metadata: JSONValue?
  public let response: JSONValue?
  public let error: GatewayOperationError?

  public init(name: String, done: Bool, metadata: JSONValue? = nil, response: JSONValue? = nil, error: GatewayOperationError? = nil) {
    self.name = name
    self.done = done
    self.metadata = metadata
    self.response = response
    self.error = error
  }
}

public struct ServiceListResult: Equatable, Sendable {
  public let project: String
  public let services: [GatewayService]
  public let pagesFetched: Int
  public let nextPageToken: String?
}

public struct ServiceGetResult: Equatable, Sendable {
  public let project: String
  public let service: GatewayService
}

public struct OperationGetResult: Equatable, Sendable {
  public let operation: GatewayOperation
}

public struct MutationResult: Equatable, Sendable {
  public let project: String
  public let requestedServices: [String]
  public let waited: Bool
  public let disableDependentServices: Bool?
  public let checkUsage: String?
  public let operation: GatewayOperation
}

extension GatewayService: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    .object(["name": .string(name), "parent": .string(parent), "serviceId": .string(serviceId), "state": .string(state.rawValue), "config": config])
  }
}

extension GatewayOperationError: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var object: [String: JSONValue] = ["code": .number(String(code)), "message": .string(message)]
    if let details { object["details"] = .array(details) }
    return .object(object)
  }
}

extension GatewayOperation: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var object: [String: JSONValue] = ["name": .string(name), "done": .bool(done)]
    if let metadata { object["metadata"] = metadata }
    if let response { object["response"] = response }
    if let error { object["error"] = error.gatewayJSONValue() }
    return .object(object)
  }
}

extension ServiceListResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var object: [String: JSONValue] = ["project": .string(project), "services": .array(services.map { $0.gatewayJSONValue() }), "pagesFetched": .number(String(pagesFetched))]
    if let nextPageToken { object["nextPageToken"] = .string(nextPageToken) }
    return .object(object)
  }
}

extension ServiceGetResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    .object(["project": .string(project), "service": service.gatewayJSONValue()])
  }
}

extension OperationGetResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue { .object(["operation": operation.gatewayJSONValue()]) }
}

extension MutationResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var object: [String: JSONValue] = ["project": .string(project), "requestedServices": .array(requestedServices.map(JSONValue.string)), "waited": .bool(waited), "operation": operation.gatewayJSONValue()]
    if let disableDependentServices { object["disableDependentServices"] = .bool(disableDependentServices) }
    if let checkUsage { object["checkUsage"] = .string(checkUsage) }
    return .object(object)
  }
}

public struct ListServicesRequest: Sendable {
  public let project: String
  public let state: ServiceListState
  public let pageSize: Int
  public let pageToken: String?
  public let allPages: Bool

  public init(project: String, state: ServiceListState = .all, pageSize: Int = 50, pageToken: String? = nil, allPages: Bool = false) {
    self.project = project
    self.state = state
    self.pageSize = pageSize
    self.pageToken = pageToken
    self.allPages = allPages
  }
}

public struct MutationOptions: Sendable {
  public let wait: Bool
  public let pollInterval: TimeInterval
  public let timeout: TimeInterval

  public init(wait: Bool = true, pollInterval: TimeInterval = 1, timeout: TimeInterval = 120) {
    self.wait = wait
    self.pollInterval = pollInterval
    self.timeout = timeout
  }
}
