import Foundation

public struct BillingAccount: Equatable, Sendable, GatewayJSONRepresentable {
  public let name: String
  public let displayName: String
  public let isOpen: Bool
  public let parentBillingAccount: String?
  public let parent: String?

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "name": .string(name), "displayName": .string(displayName), "open": .bool(isOpen)
    ]
    if let parentBillingAccount { value["masterBillingAccount"] = .string(parentBillingAccount) }
    if let parent { value["parent"] = .string(parent) }
    return .object(value)
  }
}

public struct BillingAccountPage: Equatable, Sendable, GatewayJSONRepresentable {
  public let accounts: [BillingAccount]
  public let nextPageToken: String?

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "accounts": .array(accounts.map { $0.gatewayJSONValue() })
    ]
    if let nextPageToken { value["nextPageToken"] = .string(nextPageToken) }
    return .object(value)
  }
}

public struct BillingMutationResult: Equatable, Sendable, GatewayJSONRepresentable {
  public let billing: ProjectBillingInfo
  public let providerRequestID: String?

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = ["billing": billing.gatewayJSONValue()]
    if let providerRequestID { value["providerRequestId"] = .string(providerRequestID) }
    return .object(value)
  }
}
