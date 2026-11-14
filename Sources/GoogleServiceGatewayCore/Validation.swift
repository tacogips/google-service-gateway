import Foundation

public enum GatewayValidation {
  public static let aliases = [
    "calendar": "calendar-json.googleapis.com",
    "drive": "drive.googleapis.com",
    "gmail": "gmail.googleapis.com",
    "sheets": "sheets.googleapis.com",
    "docs": "docs.googleapis.com",
  ]

  public static func project(_ input: String) throws -> String {
    let value: String
    if input.hasPrefix("projects/") {
      let parts = input.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, parts[0] == "projects" else {
        throw invalid("invalid project resource")
      }
      value = String(parts[1])
    } else {
      value = input
    }
    guard !value.isEmpty, ascii(value), !containsUnsafePathCharacter(value) else {
      throw invalid("invalid project")
    }
    if value.allSatisfy({ $0.isNumber }) {
      guard value.first != "0", value.count <= 30 else { throw invalid("invalid project number") }
    } else {
      let characters = Array(value)
      guard (6...30).contains(characters.count), characters.first?.isLetter == true,
        characters.last != "-",
        characters.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
      else {
        throw invalid("invalid project ID")
      }
      guard characters.last != "-" else { throw invalid("invalid project ID") }
    }
    return "projects/\(value)"
  }

  public static func projectID(_ input: String) throws -> String {
    guard !input.allSatisfy({ $0.isNumber }), !input.hasPrefix("projects/") else {
      throw invalid("invalid project ID")
    }
    return String(try project(input).dropFirst("projects/".count))
  }

  public static func projectDisplayName(_ value: String) throws -> String {
    let allowedPunctuation: Set<Character> = ["-", "'", "\"", " ", "!"]
    guard (4...30).contains(value.count), ascii(value),
      value.allSatisfy({ $0.isLetter || $0.isNumber || allowedPunctuation.contains($0) })
    else { throw invalid("invalid project display name") }
    return value
  }

  public static func projectParent(_ value: String) throws -> String {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, ["organizations", "folders"].contains(String(components[0])),
      !components[1].isEmpty, components[1].first != "0",
      components[1].allSatisfy({ $0.isNumber }), components[1].count <= 30
    else { throw invalid("invalid project parent") }
    return value
  }

  public static func billingAccount(_ value: String) throws -> String {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, components[0] == "billingAccounts",
      (1...64).contains(components[1].count),
      components[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else { throw invalid("invalid billing account") }
    return value
  }

  public static func projectLabels(_ labels: [String: String]) throws -> [String: String] {
    guard labels.count <= 64 else { throw invalid("a project can have at most 64 labels") }
    for (key, value) in labels {
      guard validProjectLabel(key, allowEmpty: false), validProjectLabel(value, allowEmpty: true)
      else { throw invalid("invalid project label") }
    }
    return labels
  }

  public static func service(_ input: String) throws -> String {
    let value = input.lowercased()
    if let alias = aliases[value] { return alias }
    guard !value.isEmpty, value.count <= 253, ascii(value), value.hasSuffix(".googleapis.com"),
      !containsUnsafePathCharacter(value)
    else {
      throw invalid("invalid service name")
    }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 3, labels.allSatisfy(validDNSLabel) else {
      throw invalid("invalid service name")
    }
    return value
  }

  public static func operation(_ input: String) throws -> String {
    guard input.hasPrefix("operations/") else { throw invalid("invalid operation name") }
    let suffix = input.dropFirst("operations/".count)
    guard !suffix.isEmpty, !suffix.contains("/"), !suffix.contains("?"), !suffix.contains("#"),
      !suffix.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 })
    else {
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

  public static func billingPageSize(_ value: Int) throws -> Int {
    guard (1...100).contains(value) else {
      throw invalid("billing page size must be between 1 and 100")
    }
    return value
  }

  public static func tokenEnvironmentName(_ value: String) throws -> String {
    guard ascii(value), (1...128).contains(value.count),
      value.first?.isLetter == true || value.first == "_",
      value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
    else {
      throw invalid("invalid access-token environment variable name")
    }
    return value
  }

  public static func iamPermissions(_ values: [String]) throws -> [String] {
    guard !values.isEmpty, values.count <= 100 else {
      throw invalid("between 1 and 100 IAM permissions are required")
    }
    let permissions = values
    guard Set(permissions).count == permissions.count,
      permissions.allSatisfy({ permission in
        let components = permission.split(separator: ".", omittingEmptySubsequences: false)
        return (2...8).contains(components.count) && permission.count <= 256
          && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy {
              $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
            }
          }
      })
    else { throw invalid("invalid IAM permission") }
    return permissions.sorted()
  }

  public static func apiKeyResource(_ value: String) throws -> String {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 6,
      components[0] == "projects",
      !components[1].isEmpty,
      components[2] == "locations",
      components[3] == "global",
      components[4] == "keys",
      validResourceID(String(components[5]))
    else {
      throw invalid("invalid API key resource name")
    }
    _ = try project("projects/\(components[1])")
    return value
  }

  public static func apiKeyID(_ value: String) throws -> String {
    guard value.count <= 63,
      let first = value.first,
      first.isASCII, first.isLetter,
      value.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
      value.last?.isLetter == true || value.last?.isNumber == true
    else {
      throw invalid("invalid API key ID")
    }
    return value
  }

  public static func displayName(_ value: String) throws -> String {
    guard !value.isEmpty, value.count <= 63,
      !value.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 })
    else {
      throw invalid("invalid display name")
    }
    return value
  }

  public static func apiKeyRestrictions(_ value: APIKeyRestrictions) throws -> APIKeyRestrictions {
    guard !value.apiTargets.isEmpty else { throw invalid("at least one API target is required") }
    let targets = try value.apiTargets.map { target in
      let methods = target.methods.map { $0 }
      guard
        methods.allSatisfy({
          !$0.isEmpty && !$0.contains(where: { $0.isWhitespace || $0.isNewline })
        })
      else {
        throw invalid("invalid API target method")
      }
      return APIKeyTarget(service: try service(target.service), methods: methods)
    }
    let client: APIKeyClientRestrictions
    switch value.client {
    case .none:
      client = .none
    case .browser(let values):
      guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
        throw invalid("invalid allowed referrer")
      }
      client = .browser(allowedReferrers: values)
    case .server(let values):
      guard !values.isEmpty,
        values.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isWhitespace }) })
      else { throw invalid("invalid allowed IP") }
      client = .server(allowedIPs: values)
    case .ios(let values):
      guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty && $0.contains(".") }) else {
        throw invalid("invalid bundle ID")
      }
      client = .ios(allowedBundleIDs: values)
    case .android(let values):
      guard !values.isEmpty,
        values.allSatisfy({ !$0.packageName.isEmpty && !$0.sha1Fingerprint.isEmpty })
      else { throw invalid("invalid Android application restriction") }
      client = .android(allowedApplications: values)
    }
    return APIKeyRestrictions(apiTargets: targets, client: client)
  }

  public static func polling(_ options: MutationOptions) throws {
    guard options.pollInterval.isFinite, options.pollInterval > 0, options.timeout.isFinite,
      options.timeout > 0
    else {
      throw invalid("poll interval and timeout must be finite positive values")
    }
  }

  public static func batchServices(_ services: [String]) throws -> [String] {
    guard (1...20).contains(services.count) else {
      throw invalid("batch enable requires 1 through 20 services")
    }
    let resolved = try services.map(service)
    guard Set(resolved).count == resolved.count else {
      throw invalid("batch services must be distinct")
    }
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
    guard (1...63).contains(label.count), let first = label.first, let last = label.last,
      first.isNumber || first.isLowercase, last.isNumber || last.isLowercase
    else { return false }
    return label.allSatisfy { $0.isNumber || $0.isLowercase || $0 == "-" }
  }

  private static func validProjectLabel(_ value: String, allowEmpty: Bool) -> Bool {
    if value.isEmpty { return allowEmpty }
    guard value.count <= 63, let first = value.first, let last = value.last,
      first.isLowercase, last.isLowercase || last.isNumber
    else { return false }
    return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
  }

  private static func ascii(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { $0.value < 128 }
  }

  private static func validResourceID(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128 && ascii(value)
      && value.allSatisfy {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
      }
  }

  private static func containsUnsafePathCharacter(_ value: String) -> Bool {
    value.contains { $0 == "/" || $0 == "%" || $0 == "?" || $0 == "#" || $0.isWhitespace }
  }

  private static func validPageToken(_ value: String) -> Bool {
    (1...4096).contains(value.lengthOfBytes(using: .utf8))
      && !value.unicodeScalars.contains { $0.value <= 31 || $0.value == 127 }
  }

  private static func invalid(_ message: String) -> GatewayError {
    GatewayError(.invalidArgument, message)
  }
}
