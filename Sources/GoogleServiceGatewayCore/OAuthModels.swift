import Foundation

public struct OAuthClientConfiguration: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case installed, web }

  public let kind: Kind
  public let clientID: String
  public let clientSecret: String?
  public let projectID: String?
  public let authorizationEndpoint: URL
  public let tokenEndpoint: URL
  public let redirectURIs: [URL]

  public init(
    kind: Kind,
    clientID: String,
    clientSecret: String? = nil,
    projectID: String? = nil,
    authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
    tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
    redirectURIs: [URL]
  ) {
    self.kind = kind
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.projectID = projectID
    self.authorizationEndpoint = authorizationEndpoint
    self.tokenEndpoint = tokenEndpoint
    self.redirectURIs = redirectURIs
  }

  public static func imported(from data: Data) throws -> OAuthClientConfiguration {
    struct Download: Decodable {
      struct Entry: Decodable {
        let clientID: String
        let projectID: String?
        let authURI: String
        let tokenURI: String
        let clientSecret: String?
        let redirectURIs: [String]

        enum CodingKeys: String, CodingKey {
          case clientID = "client_id"
          case projectID = "project_id"
          case authURI = "auth_uri"
          case tokenURI = "token_uri"
          case clientSecret = "client_secret"
          case redirectURIs = "redirect_uris"
        }
      }
      let installed: Entry?
      let web: Entry?
    }
    do {
      let decoded = try JSONDecoder().decode(Download.self, from: data)
      let pair: (Kind, Download.Entry)
      if let installed = decoded.installed {
        pair = (.installed, installed)
      } else if let web = decoded.web {
        pair = (.web, web)
      } else {
        throw GatewayError(
          .invalidArgument, "client JSON must contain installed or web credentials")
      }
      guard !pair.1.clientID.isEmpty,
        let authorizationEndpoint = URL(string: pair.1.authURI),
        authorizationEndpoint.scheme == "https",
        authorizationEndpoint.host == "accounts.google.com",
        let tokenEndpoint = URL(string: pair.1.tokenURI), tokenEndpoint.scheme == "https",
        tokenEndpoint.host == "oauth2.googleapis.com",
        tokenEndpoint.path == "/token"
      else {
        throw GatewayError(.invalidArgument, "client JSON contains invalid OAuth endpoints")
      }
      let redirects = pair.1.redirectURIs.compactMap(URL.init(string:))
      guard redirects.count == pair.1.redirectURIs.count, !redirects.isEmpty else {
        throw GatewayError(.invalidArgument, "client JSON contains invalid redirect URIs")
      }
      return OAuthClientConfiguration(
        kind: pair.0,
        clientID: pair.1.clientID,
        clientSecret: pair.1.clientSecret,
        projectID: pair.1.projectID,
        authorizationEndpoint: authorizationEndpoint,
        tokenEndpoint: tokenEndpoint,
        redirectURIs: redirects
      )
    } catch let error as GatewayError {
      throw error
    } catch {
      throw GatewayError(.invalidArgument, "client JSON could not be decoded")
    }
  }
}

public struct OAuthAuthorizationRequest: Equatable, Sendable {
  public let authorizationURL: URL
  public let redirectURI: URL
  public let state: String
  public let codeVerifier: String
  public let requestedScopes: [String]
}

public struct OAuthTokenCredential: Codable, Equatable, Sendable {
  public let accessToken: String
  public let refreshToken: String?
  public let tokenType: String
  public let scopes: [String]
  public let expiresAt: Date
  public let refreshTokenExpiresAt: Date?

  public init(
    accessToken: String,
    refreshToken: String?,
    tokenType: String,
    scopes: [String],
    expiresAt: Date,
    refreshTokenExpiresAt: Date? = nil
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.tokenType = tokenType
    self.scopes = scopes
    self.expiresAt = expiresAt
    self.refreshTokenExpiresAt = refreshTokenExpiresAt
  }
}

public struct OAuthScopeConfiguration: Codable, Equatable, Sendable, GatewayJSONRepresentable {
  public let project: String
  public let scopes: [String]

  public init(project: String, scopes: [String]) {
    self.project = project
    self.scopes = scopes
  }

  public func gatewayJSONValue() -> JSONValue {
    .object([
      "project": .string(project),
      "scopes": .array(scopes.map(JSONValue.string)),
    ])
  }
}

public struct OAuthProfileSummary: Equatable, Sendable, GatewayJSONRepresentable {
  public let name: String
  public let kind: OAuthClientConfiguration.Kind
  public let projectID: String?
  public let hasClientSecret: Bool
  public let hasToken: Bool

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "name": .string(name),
      "kind": .string(kind.rawValue),
      "hasClientSecret": .bool(hasClientSecret),
      "hasToken": .bool(hasToken),
    ]
    if let projectID { value["projectId"] = .string(projectID) }
    return .object(value)
  }
}

public struct OAuthSetupResult: Equatable, Sendable, GatewayJSONRepresentable {
  public let project: String
  public let consoleURL: URL
  public let automated: Bool
  public let reason: String

  public func gatewayJSONValue() -> JSONValue {
    .object([
      "project": .string(project),
      "consoleUrl": .string(consoleURL.absoluteString),
      "automated": .bool(automated),
      "reason": .string(reason),
    ])
  }
}

public struct ConsentSetupResult: Equatable, Sendable, GatewayJSONRepresentable {
  public let project: String
  public let consoleURL: URL
  public let scopes: [String]
  public let automated: Bool

  public func gatewayJSONValue() -> JSONValue {
    .object([
      "project": .string(project),
      "consoleUrl": .string(consoleURL.absoluteString),
      "scopes": .array(scopes.map(JSONValue.string)),
      "automated": .bool(automated),
    ])
  }
}

public struct OAuthTokenResult: Sendable, GatewayJSONRepresentable {
  public let accessToken: String
  public let tokenType: String
  public let scopes: [String]
  public let expiresAt: Date
  public let refreshTokenStored: Bool

  public init(
    accessToken: String, tokenType: String, scopes: [String], expiresAt: Date,
    refreshTokenStored: Bool
  ) {
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.scopes = scopes
    self.expiresAt = expiresAt
    self.refreshTokenStored = refreshTokenStored
  }

  public func gatewayJSONValue() -> JSONValue {
    .object([
      "accessToken": .string(accessToken),
      "tokenType": .string(tokenType),
      "scopes": .array(scopes.map(JSONValue.string)),
      "expiresAt": .string(ISO8601DateFormatter().string(from: expiresAt)),
      "refreshTokenStored": .bool(refreshTokenStored),
    ])
  }
}

public enum GoogleOAuthScopeCatalog {
  public static let aliases: [String: String] = [
    "openid": "openid",
    "email": "email",
    "profile": "profile",
    "cloud-platform": "https://www.googleapis.com/auth/cloud-platform",
    "calendar": "https://www.googleapis.com/auth/calendar",
    "calendar.readonly": "https://www.googleapis.com/auth/calendar.readonly",
    "calendar.events": "https://www.googleapis.com/auth/calendar.events",
    "drive": "https://www.googleapis.com/auth/drive",
    "drive.readonly": "https://www.googleapis.com/auth/drive.readonly",
    "drive.file": "https://www.googleapis.com/auth/drive.file",
    "gmail.readonly": "https://www.googleapis.com/auth/gmail.readonly",
    "gmail.modify": "https://www.googleapis.com/auth/gmail.modify",
    "gmail.send": "https://www.googleapis.com/auth/gmail.send",
    "sheets": "https://www.googleapis.com/auth/spreadsheets",
    "sheets.readonly": "https://www.googleapis.com/auth/spreadsheets.readonly",
    "docs": "https://www.googleapis.com/auth/documents",
    "docs.readonly": "https://www.googleapis.com/auth/documents.readonly",
  ]

  public static func resolve(_ values: [String]) throws -> [String] {
    let requested = values.isEmpty ? ["openid", "email", "profile"] : values
    var seen = Set<String>()
    return try requested.compactMap { value in
      let resolved: String
      if let alias = aliases[value.lowercased()] {
        resolved = alias
      } else if let url = URL(string: value), url.scheme == "https", url.host != nil {
        resolved = value
      } else {
        throw GatewayError(.invalidArgument, "unknown OAuth scope: \(value)")
      }
      return seen.insert(resolved).inserted ? resolved : nil
    }
  }
}
