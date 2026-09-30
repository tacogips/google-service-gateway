import Foundation
import Testing
@testable import GoogleServiceGatewayCore

@Test func fileCredentialsRoundTripWithoutKeychain() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = FileCredentialStore(directory: directory)
  #expect(try await store.data(for: "token:personal") == nil)
  try await store.set(Data("fixture".utf8), for: "token:personal")
  #expect(try await store.data(for: "token:personal") == Data("fixture".utf8))
  #expect(try await store.accounts(prefix: "token:") == ["token:personal"])
  let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  let file = directory.appendingPathComponent("token%3Apersonal.json")
  let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
  #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  try await store.set(Data("replacement".utf8), for: "token:personal")
  #expect(try await store.data(for: "token:personal") == Data("replacement".utf8))
  try await store.remove(account: "token:personal")
  #expect(try await store.accounts(prefix: "token:").isEmpty)
}

@Test func fileCredentialsRejectSymlinksAndPublicFiles() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = FileCredentialStore(directory: directory)
  try await store.set(Data("fixture".utf8), for: "token:personal")
  let file = directory.appendingPathComponent("token%3Apersonal.json")
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
  await #expect(throws: GatewayError.self) { try await store.data(for: "token:personal") }
  try FileManager.default.removeItem(at: file)
  try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("other"))
  await #expect(throws: GatewayError.self) { try await store.data(for: "token:personal") }
  let link = directory.appendingPathComponent("linked-directory")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
  let linked = FileCredentialStore(directory: link)
  await #expect(throws: GatewayError.self) { try await linked.set(Data(), for: "client:personal") }
}

@Test func fileCredentialsRespectProductAndXDGDirectories() async throws {
  let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: state) }
  let environment = ["XDG_STATE_HOME": state.path]
  let service = FileCredentialStore(environment: environment)
  let gmail = FileCredentialStore(productDirectory: "gmail-gateway", environment: environment)
  try await service.set(Data("service".utf8), for: "client:personal")
  #expect(try await gmail.data(for: "client:personal") == nil)
  #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("google-service-gateway/credentials/client%3Apersonal.json").path))
}
