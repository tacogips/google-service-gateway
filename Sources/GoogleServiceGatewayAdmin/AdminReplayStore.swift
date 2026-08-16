import Foundation
import GoogleServiceGatewayCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct FileAdminPlanReplayStore: AdminPlanReplayStore {
  private let directory: URL

  init(path: String) throws {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw GatewayError(.invalidArgument, "admin state directory must be an absolute path")
    }
    directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw GatewayError(.configurationError, "admin state path must be a real directory")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  }

  func consume(planID: String, digest _: String) async throws {
    guard !planID.isEmpty, planID.count <= 64,
      planID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else { throw GatewayError(.failedPrecondition, "admin plan identifier is invalid") }
    let path = directory.appendingPathComponent("consumed-\(planID)", isDirectory: false).path
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw GatewayError(.failedPrecondition, "admin plan has already been consumed")
      }
      throw GatewayError(.configurationError, "could not persist admin plan consumption")
    }
    guard close(descriptor) == 0 else {
      throw GatewayError(.configurationError, "could not finalize admin plan consumption")
    }
  }
}
