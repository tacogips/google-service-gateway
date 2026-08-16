import Foundation

public enum BillingAdminOperation: String, Equatable, Sendable {
  case link = "billing.projects.link"
  case unlink = "billing.projects.unlink"
}

public protocol GatewayWallClock: Sendable {
  func now() -> Date
}

public struct SystemGatewayWallClock: GatewayWallClock {
  public init() {}
  public func now() -> Date { Date() }
}

public protocol GatewayNonceProvider: Sendable {
  func nonce() -> String
}

public struct UUIDGatewayNonceProvider: GatewayNonceProvider {
  public init() {}
  public func nonce() -> String { UUID().uuidString.lowercased() }
}

public protocol AdminPlanReplayStore: Sendable {
  func consume(planID: String, digest: String) async throws
}

public struct BillingAdminPlan: Equatable, Sendable, GatewayJSONRepresentable {
  public let schemaVersion: Int
  public let planID: String
  public let operation: BillingAdminOperation
  public let project: String
  public let currentBilling: ProjectBillingInfo
  public let currentFingerprint: String
  public let desiredBillingAccount: String?
  public let credentialSelector: String
  public let createdAt: String
  public let expiresAt: String
  public let requiredPermissions: [String]
  public let warnings: [String]
  public let digest: String
  public let signature: String

  public func gatewayJSONValue() -> JSONValue {
    var value = unsignedJSON()
    guard case .object(var object) = value else { return value }
    object["digest"] = .string(digest)
    object["signature"] = .string(signature)
    value = .object(object)
    return value
  }

  public static func decode(_ data: Data) throws -> BillingAdminPlan {
    let root = try GatewayJSONCodec.decode(data)
    let value: JSONValue
    if case .object(let envelope) = root, let data = envelope["data"] {
      value = data
    } else {
      value = root
    }
    guard case .object(let object) = value,
      case .number(let schemaRaw) = object["schemaVersion"], let schema = Int(schemaRaw),
      case .string(let planID) = object["planId"],
      case .string(let operationRaw) = object["operation"],
      let operation = BillingAdminOperation(rawValue: operationRaw),
      case .string(let project) = object["project"],
      case .object(let current) = object["currentBilling"],
      case .string(let currentFingerprint) = object["currentFingerprint"],
      case .string(let credentialSelector) = object["credentialSelector"],
      case .string(let createdAt) = object["createdAt"],
      case .string(let expiresAt) = object["expiresAt"],
      case .array(let permissionValues) = object["requiredPermissions"],
      case .array(let warningValues) = object["warnings"],
      case .string(let digest) = object["digest"],
      case .string(let signature) = object["signature"]
    else { throw invalidPlan() }
    let warnings = try warningValues.map { value -> String in
      guard case .string(let warning) = value else { throw invalidPlan() }
      return warning
    }
    let permissions = try permissionValues.map { value -> String in
      guard case .string(let permission) = value else { throw invalidPlan() }
      return permission
    }
    let desired: String?
    switch object["desiredBillingAccount"] {
    case .string(let account): desired = account
    case .null: desired = nil
    default: throw invalidPlan()
    }
    guard case .string(let projectID) = current["projectId"],
      case .bool(let enabled) = current["billingEnabled"]
    else { throw invalidPlan() }
    let currentAccount: String?
    switch current["billingAccount"] {
    case .string(let account): currentAccount = account
    case nil: currentAccount = nil
    default: throw invalidPlan()
    }
    return BillingAdminPlan(
      schemaVersion: schema, planID: planID, operation: operation, project: project,
      currentBilling: ProjectBillingInfo(
        projectID: projectID, billingAccount: currentAccount, billingEnabled: enabled),
      currentFingerprint: currentFingerprint, desiredBillingAccount: desired,
      credentialSelector: credentialSelector, createdAt: createdAt, expiresAt: expiresAt,
      requiredPermissions: permissions, warnings: warnings, digest: digest, signature: signature)
  }

  fileprivate func unsignedJSON() -> JSONValue {
    .object([
      "schemaVersion": .number(String(schemaVersion)),
      "planId": .string(planID),
      "operation": .string(operation.rawValue),
      "project": .string(project),
      "currentBilling": currentBilling.gatewayJSONValue(),
      "currentFingerprint": .string(currentFingerprint),
      "desiredBillingAccount": desiredBillingAccount.map(JSONValue.string) ?? .null,
      "credentialSelector": .string(credentialSelector),
      "createdAt": .string(createdAt),
      "expiresAt": .string(expiresAt),
      "requiredPermissions": .array(requiredPermissions.map(JSONValue.string)),
      "warnings": .array(warnings.map(JSONValue.string))
    ])
  }
}

public struct BillingAdminApplyResult: Equatable, Sendable, GatewayJSONRepresentable {
  public let actor: String
  public let operation: BillingAdminOperation
  public let project: String
  public let planDigest: String
  public let beforeFingerprint: String
  public let afterFingerprint: String
  public let providerRequestID: String?

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "actor": .string(actor), "operation": .string(operation.rawValue),
      "project": .string(project), "planDigest": .string(planDigest),
      "beforeFingerprint": .string(beforeFingerprint),
      "afterFingerprint": .string(afterFingerprint)
    ]
    if let providerRequestID { value["providerRequestId"] = .string(providerRequestID) }
    return .object(value)
  }
}

public struct GoogleCloudBillingAdmin: Sendable {
  private let billing: GoogleCloudBillingClient
  private let clock: any GatewayWallClock
  private let nonceProvider: any GatewayNonceProvider

  public init(
    billing: GoogleCloudBillingClient,
    clock: any GatewayWallClock = SystemGatewayWallClock(),
    nonceProvider: any GatewayNonceProvider = UUIDGatewayNonceProvider()
  ) {
    self.billing = billing
    self.clock = clock
    self.nonceProvider = nonceProvider
  }

  public func plan(
    operation: BillingAdminOperation,
    project inputProject: String,
    billingAccount inputAccount: String?,
    credentialSelector: String,
    signingKey: Data,
    lifetime: TimeInterval = 600
  ) async throws -> BillingAdminPlan {
    let project = try GatewayValidation.project(inputProject)
    let desired = try inputAccount.map(GatewayValidation.billingAccount)
    guard (operation == .link && desired != nil) || (operation == .unlink && desired == nil),
      (60...3600).contains(lifetime), signingKey.count >= 32,
      !credentialSelector.isEmpty, credentialSelector.count <= 256
    else { throw GatewayError(.invalidArgument, "invalid billing admin plan input") }
    let current = try await billing.getProjectBilling(project)
    if operation == .link, current.billingAccount == desired {
      throw GatewayError(.failedPrecondition, "project is already linked to that billing account")
    }
    if operation == .unlink, current.billingAccount == nil {
      throw GatewayError(.failedPrecondition, "project is not linked to a billing account")
    }
    let now = clock.now()
    let unsigned = BillingAdminPlan(
      schemaVersion: 1,
      planID: nonceProvider.nonce(),
      operation: operation,
      project: project,
      currentBilling: current,
      currentFingerprint: try fingerprint(current),
      desiredBillingAccount: desired,
      credentialSelector: credentialSelector,
      createdAt: timestamp(now),
      expiresAt: timestamp(now.addingTimeInterval(lifetime)),
      requiredPermissions: operation == .link
        ? ["billing.resourceAssociations.create", "resourcemanager.projects.createBillingAssignment"]
        : ["billing.resourceAssociations.delete", "resourcemanager.projects.deleteBillingAssignment"],
      warnings: operation == .link
        ? ["This changes the project charging boundary."]
        : ["Billable services can stop after billing is unlinked."],
      digest: "",
      signature: ""
    )
    let bytes = try GatewayJSONCodec.encode(unsigned.unsignedJSON())
    return BillingAdminPlan(
      schemaVersion: unsigned.schemaVersion, planID: unsigned.planID,
      operation: unsigned.operation, project: unsigned.project,
      currentBilling: unsigned.currentBilling,
      currentFingerprint: unsigned.currentFingerprint,
      desiredBillingAccount: unsigned.desiredBillingAccount,
      credentialSelector: unsigned.credentialSelector,
      createdAt: unsigned.createdAt, expiresAt: unsigned.expiresAt,
      requiredPermissions: unsigned.requiredPermissions, warnings: unsigned.warnings,
      digest: GatewayDigest.sha256Hex(bytes),
      signature: GatewayDigest.hmacSHA256Hex(key: signingKey, message: bytes)
    )
  }

  public func apply(
    _ plan: BillingAdminPlan,
    expectedOperation: BillingAdminOperation,
    credentialSelector: String,
    signingKey: Data,
    replayStore: any AdminPlanReplayStore
  ) async throws -> BillingAdminApplyResult {
    guard plan.schemaVersion == 1, plan.operation == expectedOperation,
      plan.credentialSelector == credentialSelector, signingKey.count >= 32
    else { throw invalidPlan() }
    let bytes = try GatewayJSONCodec.encode(plan.unsignedJSON())
    let digest = GatewayDigest.sha256Hex(bytes)
    let signature = GatewayDigest.hmacSHA256Hex(key: signingKey, message: bytes)
    guard GatewayDigest.constantTimeEqual(plan.digest, digest),
      GatewayDigest.constantTimeEqual(plan.signature, signature),
      let expiry = parseTimestamp(plan.expiresAt), clock.now() < expiry
    else { throw invalidPlan() }
    let current = try await billing.getProjectBilling(plan.project)
    guard try fingerprint(current) == plan.currentFingerprint, current == plan.currentBilling else {
      throw GatewayError(.failedPrecondition, "billing state changed after plan creation")
    }
    try await replayStore.consume(planID: plan.planID, digest: plan.digest)
    let mutation = try await billing.updateProjectBilling(
      project: plan.project, billingAccount: plan.desiredBillingAccount)
    return BillingAdminApplyResult(
      actor: credentialSelector, operation: plan.operation, project: plan.project,
      planDigest: plan.digest, beforeFingerprint: plan.currentFingerprint,
      afterFingerprint: try fingerprint(mutation.billing),
      providerRequestID: mutation.providerRequestID)
  }
}

private func fingerprint(_ value: ProjectBillingInfo) throws -> String {
  GatewayDigest.sha256Hex(try GatewayJSONCodec.encode(value))
}

private func timestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}

private func parseTimestamp(_ value: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: value)
}

private func invalidPlan() -> GatewayError {
  GatewayError(.failedPrecondition, "admin plan is invalid, expired, or does not match this apply")
}
