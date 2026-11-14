import Foundation

#if canImport(Security)
  import Security
#endif

public protocol SecureCredentialStore: Sendable {
  func data(for account: String) async throws -> Data?
  func set(_ data: Data, for account: String) async throws
  func remove(account: String) async throws
  func accounts(prefix: String) async throws -> [String]
}

public struct KeychainCredentialStore: SecureCredentialStore {
  private let service: String

  public init(service: String = "com.tacogips.google-service-gateway") {
    self.service = service
  }

  public func data(for account: String) async throws -> Data? {
    #if canImport(Security)
      var item: CFTypeRef?
      let status = SecItemCopyMatching(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
          kSecReturnData as String: true,
          kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data else { throw keychainError(status) }
      return data
    #else
      throw GatewayError(
        .configurationError, "secure credential storage is unavailable on this platform")
    #endif
  }

  public func set(_ data: Data, for account: String) async throws {
    #if canImport(Security)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      let status = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
      } else if status != errSecSuccess {
        throw keychainError(status)
      }
    #else
      throw GatewayError(
        .configurationError, "secure credential storage is unavailable on this platform")
    #endif
  }

  public func remove(account: String) async throws {
    #if canImport(Security)
      let status = SecItemDelete(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
        ] as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw keychainError(status)
      }
    #else
      throw GatewayError(
        .configurationError, "secure credential storage is unavailable on this platform")
    #endif
  }

  public func accounts(prefix: String) async throws -> [String] {
    #if canImport(Security)
      var result: CFTypeRef?
      let status = SecItemCopyMatching(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecReturnAttributes as String: true,
          kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &result)
      if status == errSecItemNotFound { return [] }
      guard status == errSecSuccess else { throw keychainError(status) }
      let entries = result as? [[String: Any]] ?? []
      return entries.compactMap { $0[kSecAttrAccount as String] as? String }
        .filter { $0.hasPrefix(prefix) }
        .sorted()
    #else
      throw GatewayError(
        .configurationError, "secure credential storage is unavailable on this platform")
    #endif
  }
}

#if canImport(Security)
  private func keychainError(_ status: OSStatus) -> GatewayError {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown keychain error"
    return GatewayError(.configurationError, "Keychain operation failed: \(message)")
  }
#endif

public struct OAuthCredentialVault: Sendable {
  private let store: any SecureCredentialStore

  public init(store: any SecureCredentialStore = KeychainCredentialStore()) { self.store = store }

  public func saveClient(_ client: OAuthClientConfiguration, profile: String) async throws {
    try await store.set(
      try JSONEncoder().encode(client), for: clientAccount(try profileName(profile)))
  }

  public func client(profile: String) async throws -> OAuthClientConfiguration {
    let profile = try profileName(profile)
    guard let data = try await store.data(for: clientAccount(profile)) else {
      throw GatewayError(.configurationError, "OAuth client profile not found")
    }
    do { return try JSONDecoder().decode(OAuthClientConfiguration.self, from: data) } catch {
      throw GatewayError(.configurationError, "stored OAuth client profile is invalid")
    }
  }

  public func saveToken(_ token: OAuthTokenCredential, profile: String) async throws {
    try await store.set(
      try JSONEncoder().encode(token), for: tokenAccount(try profileName(profile)))
  }

  public func token(profile: String) async throws -> OAuthTokenCredential? {
    let profile = try profileName(profile)
    guard let data = try await store.data(for: tokenAccount(profile)) else { return nil }
    do { return try JSONDecoder().decode(OAuthTokenCredential.self, from: data) } catch {
      throw GatewayError(.configurationError, "stored OAuth token is invalid")
    }
  }

  public func removeToken(profile: String) async throws {
    try await store.remove(account: tokenAccount(try profileName(profile)))
  }

  public func saveScopeConfiguration(_ configuration: OAuthScopeConfiguration, profile: String)
    async throws
  {
    try await store.set(
      try JSONEncoder().encode(configuration), for: scopeAccount(try profileName(profile)))
  }

  public func scopeConfiguration(profile: String) async throws -> OAuthScopeConfiguration? {
    let profile = try profileName(profile)
    guard let data = try await store.data(for: scopeAccount(profile)) else { return nil }
    do { return try JSONDecoder().decode(OAuthScopeConfiguration.self, from: data) } catch {
      throw GatewayError(.configurationError, "stored OAuth scope configuration is invalid")
    }
  }

  public func removeScopeConfiguration(profile: String) async throws {
    try await store.remove(account: scopeAccount(try profileName(profile)))
  }

  public func removeProfile(_ profile: String) async throws {
    let profile = try profileName(profile)
    try await store.remove(account: clientAccount(profile))
    try await store.remove(account: tokenAccount(profile))
    try await store.remove(account: scopeAccount(profile))
  }

  public func profiles() async throws -> [OAuthProfileSummary] {
    let accounts = try await store.accounts(prefix: "client:")
    return try await accounts.asyncMap { account in
      let name = String(account.dropFirst("client:".count))
      let client = try await client(profile: name)
      return OAuthProfileSummary(
        name: name,
        kind: client.kind,
        projectID: client.projectID,
        hasClientSecret: !(client.clientSecret?.isEmpty ?? true),
        hasToken: try await token(profile: name) != nil
      )
    }
  }

  private func profileName(_ value: String) throws -> String {
    guard !value.isEmpty, value.count <= 64,
      value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else {
      throw GatewayError(.invalidArgument, "invalid OAuth profile name")
    }
    return value
  }

  private func clientAccount(_ profile: String) -> String { "client:\(profile)" }
  private func tokenAccount(_ profile: String) -> String { "token:\(profile)" }
  private func scopeAccount(_ profile: String) -> String { "scopes:\(profile)" }
}

extension Array {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var values: [T] = []
    values.reserveCapacity(count)
    for element in self { values.append(try await transform(element)) }
    return values
  }
}
