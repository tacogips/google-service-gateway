import Foundation
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Native OAuth storage. Keychain remains available only through explicit injection.
public struct FileCredentialStore: SecureCredentialStore {
  private let directory: URL
  private let validConfiguration: Bool

  public init(
    productDirectory: String = "google-service-gateway",
    environment: [String: String] = ProcessInfo.processInfo.environment,
    directory: URL? = nil
  ) {
    let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    let state = environment["XDG_STATE_HOME"] ?? home + "/.local/state"
    validConfiguration = directory != nil || (state.hasPrefix("/") && !productDirectory.isEmpty
      && productDirectory.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
        || (48...57).contains($0) || [45, 95].contains($0) })
    self.directory = directory ?? URL(fileURLWithPath: state)
      .appendingPathComponent(productDirectory).appendingPathComponent("credentials")
  }

  public func data(for account: String) async throws -> Data? {
    let root = try openDirectory(create: false)
    guard let root else { return nil }
    defer { close(root) }
    let descriptor = openat(root, try filename(account), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw storageError() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
      info.st_size <= 1_048_576
    else { throw storageError() }
    let bytes = try handle.read(upToCount: 1_048_577) ?? Data()
    guard bytes.count <= 1_048_576 else { throw storageError() }
    return bytes
  }

  public func set(_ data: Data, for account: String) async throws {
    guard data.count <= 1_048_576, let root = try openDirectory(create: true) else {
      throw storageError()
    }
    defer { close(root) }
    let name = try filename(account)
    let temporary = "." + UUID().uuidString
    let descriptor = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw storageError() }
    defer { close(descriptor); _ = unlinkat(root, temporary, 0) }
    guard fchmod(descriptor, 0o600) == 0 else { throw storageError() }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw storageError() }
        offset += count
      }
    }
    guard fsync(descriptor) == 0, renameat(root, temporary, root, name) == 0 else {
      throw storageError()
    }
  }

  public func remove(account: String) async throws {
    guard let root = try openDirectory(create: false) else { return }
    defer { close(root) }
    if unlinkat(root, try filename(account), 0) != 0, errno != ENOENT { throw storageError() }
  }

  public func accounts(prefix: String) async throws -> [String] {
    guard let root = try openDirectory(create: false) else { return [] }
    defer { close(root) }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .compactMap { name in
        guard name.hasSuffix(".json") else { return nil }
        let encoded = String(name.dropLast(5))
        guard let account = encoded.removingPercentEncoding, account.hasPrefix(prefix),
          (try? filename(account)) == name else { return nil }
        return account
      }.sorted()
  }

  private func filename(_ account: String) throws -> String {
    guard !account.isEmpty, account.utf8.count <= 128,
      let encoded = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded.utf8.count <= 240
    else { throw storageError() }
    return encoded + ".json"
  }

  private func openDirectory(create: Bool) throws -> Int32? {
    let components = directory.pathComponents.dropFirst()
    guard validConfiguration, directory.path.hasPrefix("/"), !components.isEmpty else { throw storageError() }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw storageError() }
    var path = ""
    do {
      for component in components {
        guard component != ".", component != ".." else { throw storageError() }
        path += "/" + component
        var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if next < 0, ["/var", "/tmp"].contains(path) {
          var info = stat()
          if lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFLNK {
            next = openat(descriptor, component, O_RDONLY | O_DIRECTORY)
          }
        }
        if next < 0, errno == ENOENT {
          if !create { close(descriptor); return nil }
          guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
            throw storageError()
          }
          next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard next >= 0 else { throw storageError() }
        close(descriptor)
        descriptor = next
      }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
        throw storageError()
      }
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private func storageError() -> GatewayError {
    GatewayError(.configurationError, "Credential storage requires a private, owner-controlled directory and regular files")
  }
}
