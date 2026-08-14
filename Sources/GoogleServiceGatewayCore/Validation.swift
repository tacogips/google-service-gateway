import Foundation

public enum GatewayValidation {
  public static let aliases = [
    "calendar": "calendar-json.googleapis.com",
    "drive": "drive.googleapis.com",
    "gmail": "gmail.googleapis.com",
    "sheets": "sheets.googleapis.com",
    "docs": "docs.googleapis.com"
  ]

  public static func project(_ input: String) throws -> String {
    let value: String
    if input.hasPrefix("projects/") {
      let parts = input.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, parts[0] == "projects" else { throw invalid("invalid project resource") }
      value = String(parts[1])
    } else {
      value = input
    }
    guard !value.isEmpty, ascii(value), !containsUnsafePathCharacter(value) else { throw invalid("invalid project") }
    if value.allSatisfy({ $0.isNumber }) {
      guard value.first != "0", value.count <= 30 else { throw invalid("invalid project number") }
    } else {
      let characters = Array(value)
      guard (6...30).contains(characters.count), characters.first?.isLetter == true,
        characters.last != "-",
        characters.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else {
        throw invalid("invalid project ID")
      }
      guard characters.last != "-" else { throw invalid("invalid project ID") }
    }
    return "projects/\(value)"
  }

  public static func service(_ input: String) throws -> String {
    let value = input.lowercased()
    if let alias = aliases[value] { return alias }
    guard !value.isEmpty, value.count <= 253, ascii(value), value.hasSuffix(".googleapis.com"), !containsUnsafePathCharacter(value) else {
      throw invalid("invalid service name")
    }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 3, labels.allSatisfy(validDNSLabel) else { throw invalid("invalid service name") }
    return value
  }

  public static func operation(_ input: String) throws -> String {
    guard input.hasPrefix("operations/") else { throw invalid("invalid operation name") }
    let suffix = input.dropFirst("operations/".count)
    guard !suffix.isEmpty, !suffix.contains("/"), !suffix.contains("?"), !suffix.contains("#"), !suffix.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 }) else {
      throw invalid("invalid operation name")
    }
    return input
  }

  public static func pageToken(_ input: String?) throws -> String? {
    guard let input else { return nil }
    guard validPageToken(input) else {
      throw invalid("invalid page token")
    }
    return input
  }

  static func returnedPageToken(_ input: String?) throws -> String? {
    guard let input, !input.isEmpty else { return nil }
    guard validPageToken(input) else {
      throw GatewayError(.malformedResponse, "provider returned an invalid page token")
    }
    return input
  }

  public static func pageSize(_ value: Int) throws -> Int {
    guard (1...200).contains(value) else { throw invalid("page size must be between 1 and 200") }
    return value
  }

  public static func tokenEnvironmentName(_ value: String) throws -> String {
    guard ascii(value), (1...128).contains(value.count), value.first?.isLetter == true || value.first == "_", value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
      throw invalid("invalid access-token environment variable name")
    }
    return value
  }

  public static func polling(_ options: MutationOptions) throws {
    guard options.pollInterval.isFinite, options.pollInterval > 0, options.timeout.isFinite, options.timeout > 0 else {
      throw invalid("poll interval and timeout must be finite positive values")
    }
  }

  public static func batchServices(_ services: [String]) throws -> [String] {
    guard (1...20).contains(services.count) else { throw invalid("batch enable requires 1 through 20 services") }
    let resolved = try services.map(service)
    guard Set(resolved).count == resolved.count else { throw invalid("batch services must be distinct") }
    return resolved
  }

  static func percentEncodePathSegment(_ value: String) -> String {
    value.utf8.map { byte in
      switch byte {
      case 45, 46, 48...57, 65...90, 95, 97...122: String(UnicodeScalar(byte))
      default: String(format: "%%%02X", byte)
      }
    }.joined()
  }

  private static func validDNSLabel(_ label: Substring) -> Bool {
    guard (1...63).contains(label.count), let first = label.first, let last = label.last, first.isNumber || first.isLowercase, last.isNumber || last.isLowercase else { return false }
    return label.allSatisfy { $0.isNumber || $0.isLowercase || $0 == "-" }
  }

  private static func ascii(_ value: String) -> Bool { value.unicodeScalars.allSatisfy { $0.value < 128 } }

  private static func containsUnsafePathCharacter(_ value: String) -> Bool {
    value.contains { $0 == "/" || $0 == "%" || $0 == "?" || $0 == "#" || $0.isWhitespace }
  }

  private static func validPageToken(_ value: String) -> Bool {
    (1...4096).contains(value.lengthOfBytes(using: .utf8)) &&
      !value.unicodeScalars.contains { $0.value <= 31 || $0.value == 127 }
  }

  private static func invalid(_ message: String) -> GatewayError { GatewayError(.invalidArgument, message) }
}
