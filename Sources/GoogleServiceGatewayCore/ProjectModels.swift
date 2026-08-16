import Foundation

public struct CreateProjectRequest: Sendable {
  public let projectID: String
  public let displayName: String
  public let parent: String?
  public let labels: [String: String]
  public let billingAccount: String?
  public let services: [String]
  public let oauthScopes: [String]
  public let options: MutationOptions

  public init(
    projectID: String,
    displayName: String,
    parent: String? = nil,
    labels: [String: String] = [:],
    billingAccount: String? = nil,
    services: [String] = [],
    oauthScopes: [String] = [],
    options: MutationOptions = MutationOptions()
  ) {
    self.projectID = projectID
    self.displayName = displayName
    self.parent = parent
    self.labels = labels
    self.billingAccount = billingAccount
    self.services = services
    self.oauthScopes = oauthScopes
    self.options = options
  }
}

public struct GatewayProject: Equatable, Sendable, GatewayJSONRepresentable {
  public let resourceName: String
  public let projectID: String
  public let displayName: String
  public let parent: String?
  public let state: String
  public let labels: [String: String]
  public let createTime: String?

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "resourceName": .string(resourceName),
      "projectId": .string(projectID),
      "displayName": .string(displayName),
      "state": .string(state),
      "labels": .object(labels.mapValues(JSONValue.string))
    ]
    if let parent { value["parent"] = .string(parent) }
    if let createTime { value["createTime"] = .string(createTime) }
    return .object(value)
  }
}

public struct ProjectBillingInfo: Equatable, Sendable, GatewayJSONRepresentable {
  public let projectID: String
  public let billingAccount: String?
  public let billingEnabled: Bool

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "projectId": .string(projectID),
      "billingEnabled": .bool(billingEnabled)
    ]
    if let billingAccount { value["billingAccount"] = .string(billingAccount) }
    return .object(value)
  }
}

public struct ProjectProvisioningResult: Equatable, Sendable, GatewayJSONRepresentable {
  public let projectID: String
  public let project: GatewayProject?
  public let createOperation: GatewayOperation
  public let billing: ProjectBillingInfo?
  public let serviceEnablement: MutationResult?
  public let oauthClientSetup: OAuthSetupResult
  public let oauthConsentSetup: ConsentSetupResult

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "projectId": .string(projectID),
      "createOperation": createOperation.gatewayJSONValue(),
      "oauthClientSetup": oauthClientSetup.gatewayJSONValue(),
      "oauthConsentSetup": oauthConsentSetup.gatewayJSONValue()
    ]
    if let project { value["project"] = project.gatewayJSONValue() }
    if let billing { value["billing"] = billing.gatewayJSONValue() }
    if let serviceEnablement { value["serviceEnablement"] = serviceEnablement.gatewayJSONValue() }
    return .object(value)
  }
}

public enum ProjectLifecycleAction: String, Sendable {
  case delete
  case undelete
}

public struct ProjectLifecycleResult: Equatable, Sendable, GatewayJSONRepresentable {
  public let project: String
  public let action: ProjectLifecycleAction
  public let waited: Bool
  public let operation: GatewayOperation

  public init(
    project: String,
    action: ProjectLifecycleAction,
    waited: Bool,
    operation: GatewayOperation
  ) {
    self.project = project
    self.action = action
    self.waited = waited
    self.operation = operation
  }

  public func gatewayJSONValue() -> JSONValue {
    .object([
      "project": .string(project),
      "action": .string(action.rawValue),
      "waited": .bool(waited),
      "operation": operation.gatewayJSONValue()
    ])
  }
}
