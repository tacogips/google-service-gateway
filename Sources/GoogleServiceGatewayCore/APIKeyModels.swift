import Foundation

public struct APIKeyTarget: Equatable, Sendable {
  public let service: String
  public let methods: [String]

  public init(service: String, methods: [String] = []) {
    self.service = service
    self.methods = methods
  }
}

public struct AndroidApplicationRestriction: Equatable, Sendable {
  public let packageName: String
  public let sha1Fingerprint: String

  public init(packageName: String, sha1Fingerprint: String) {
    self.packageName = packageName
    self.sha1Fingerprint = sha1Fingerprint
  }
}

public enum APIKeyClientRestrictions: Equatable, Sendable {
  case none
  case browser(allowedReferrers: [String])
  case server(allowedIPs: [String])
  case ios(allowedBundleIDs: [String])
  case android(allowedApplications: [AndroidApplicationRestriction])
}

public struct APIKeyRestrictions: Equatable, Sendable {
  public let apiTargets: [APIKeyTarget]
  public let client: APIKeyClientRestrictions

  public init(apiTargets: [APIKeyTarget], client: APIKeyClientRestrictions = .none) {
    self.apiTargets = apiTargets
    self.client = client
  }
}

public struct APIKeyResource: Equatable, Sendable {
  public let name: String
  public let uid: String?
  public let displayName: String
  public let createTime: String?
  public let updateTime: String?
  public let deleteTime: String?
  public let etag: String?
  public let restrictions: APIKeyRestrictions?

  public init(
    name: String,
    uid: String? = nil,
    displayName: String,
    createTime: String? = nil,
    updateTime: String? = nil,
    deleteTime: String? = nil,
    etag: String? = nil,
    restrictions: APIKeyRestrictions? = nil
  ) {
    self.name = name
    self.uid = uid
    self.displayName = displayName
    self.createTime = createTime
    self.updateTime = updateTime
    self.deleteTime = deleteTime
    self.etag = etag
    self.restrictions = restrictions
  }
}

public struct APIKeyListResult: Equatable, Sendable {
  public let project: String
  public let keys: [APIKeyResource]
  public let nextPageToken: String?
}

public struct APIKeyGetResult: Equatable, Sendable {
  public let key: APIKeyResource
}

public struct APIKeyStringResult: Equatable, Sendable {
  public let name: String
  public let keyString: String
}

public struct APIKeyMutationResult: Equatable, Sendable {
  public let operation: GatewayOperation
  public let waited: Bool
}

public struct CreateAPIKeyRequest: Sendable {
  public let project: String
  public let displayName: String
  public let keyID: String?
  public let restrictions: APIKeyRestrictions
  public let options: MutationOptions

  public init(
    project: String,
    displayName: String,
    keyID: String? = nil,
    restrictions: APIKeyRestrictions,
    options: MutationOptions = MutationOptions()
  ) {
    self.project = project
    self.displayName = displayName
    self.keyID = keyID
    self.restrictions = restrictions
    self.options = options
  }
}

extension APIKeyTarget: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = ["service": .string(service)]
    if !methods.isEmpty { value["methods"] = .array(methods.map(JSONValue.string)) }
    return .object(value)
  }
}

extension AndroidApplicationRestriction: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    .object(["packageName": .string(packageName), "sha1Fingerprint": .string(sha1Fingerprint)])
  }
}

extension APIKeyRestrictions: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "apiTargets": .array(apiTargets.map { $0.gatewayJSONValue() })
    ]
    switch client {
    case .none:
      break
    case .browser(let values):
      value["browserKeyRestrictions"] = .object([
        "allowedReferrers": .array(values.map(JSONValue.string))
      ])
    case .server(let values):
      value["serverKeyRestrictions"] = .object(["allowedIps": .array(values.map(JSONValue.string))])
    case .ios(let values):
      value["iosKeyRestrictions"] = .object([
        "allowedBundleIds": .array(values.map(JSONValue.string))
      ])
    case .android(let values):
      value["androidKeyRestrictions"] = .object([
        "allowedApplications": .array(values.map { $0.gatewayJSONValue() })
      ])
    }
    return .object(value)
  }
}

extension APIKeyResource: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = ["name": .string(name), "displayName": .string(displayName)]
    if let uid { value["uid"] = .string(uid) }
    if let createTime { value["createTime"] = .string(createTime) }
    if let updateTime { value["updateTime"] = .string(updateTime) }
    if let deleteTime { value["deleteTime"] = .string(deleteTime) }
    if let etag { value["etag"] = .string(etag) }
    if let restrictions { value["restrictions"] = restrictions.gatewayJSONValue() }
    return .object(value)
  }
}

extension APIKeyListResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "project": .string(project),
      "keys": .array(keys.map { $0.gatewayJSONValue() }),
    ]
    if let nextPageToken { value["nextPageToken"] = .string(nextPageToken) }
    return .object(value)
  }
}

extension APIKeyGetResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue { .object(["key": key.gatewayJSONValue()]) }
}

extension APIKeyStringResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    .object(["name": .string(name), "keyString": .string(keyString)])
  }
}

extension APIKeyMutationResult: GatewayJSONRepresentable {
  public func gatewayJSONValue() -> JSONValue {
    .object(["operation": operation.gatewayJSONValue(), "waited": .bool(waited)])
  }
}
