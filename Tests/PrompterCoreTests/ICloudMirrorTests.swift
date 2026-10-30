import XCTest
@testable import VideoPrompter
import PrompterCore

/// A script linked to a file outside iCloud Drive gets a mirror in the iCloud folder, kept in
/// step both ways. Runs against a throwaway library, master file and "iCloud Drive".
@MainActor
final class ICloudMirrorTests: XCTestCase {
  private var dirs: [URL] = []
  private let keys = [ICloudScripts.enabledKey, ICloudScripts.mirrorsKey, ICloudScripts.declinedMirrorsKey, ICloudScripts.unlinkPendingKey]

  override func tearDown() async throws {
    ICloudScripts.cloudDocsOverride = nil
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    for url in dirs { try? FileManager.default.removeItem(at: url) }
  }

  private func temp(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    dirs.append(url)
    return url
  }

  private func pass(_ store: AppStore) async {
    ICloudScripts.lastPass = .distantPast
    await store.syncICloudScripts()
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  /// A store with one script linked to `master.md`, mirrored by a first pass.
  private func mirroredStore() async throws -> (AppStore, UUID, master: URL, mirror: URL) {
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    ICloudScripts.cloudDocsOverride = try temp("CloudDocs")
    UserDefaults.standard.set(true, forKey: ICloudScripts.enabledKey)
    let root = try temp("vp-lib"), outside = try temp("vp-notes")
    let store = AppStore(
      arguments: ["test", "--data-directory", root.path],
      defaults: UserDefaults(suiteName: "ICloudMirrorTests.\(UUID().uuidString)")!)
    let master = outside.appendingPathComponent("master.md")
    try Data("Original text.\n".utf8).write(to: master)
    let record = try await store.library!.create(title: "Linked", markdown: "Original text.\n")
    _ = try await store.library!.link(record.id, to: master)
    await store.reload()
    await pass(store)
    let mirror = ICloudScripts.folder.appendingPathComponent("Linked.md")
    XCTAssertEqual(try text(mirror), "Original text.\n")
    XCTAssertEqual(ICloudScripts.mirrors[record.id]?.path, mirror.standardizedFileURL.path)
    return (store, record.id, master, mirror)
  }

  func testAnIPadEditReachesTheScriptAndItsMasterFile() async throws {
    let (store, id, master, mirror) = try await mirroredStore()
    try Data("Edited on the iPad.\n".utf8).write(to: mirror, options: .atomic)
    await pass(store)
    XCTAssertEqual(store.scripts.first { $0.id == id }?.markdown, "Edited on the iPad.\n")
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    XCTAssertEqual(try text(master), "Edited on the iPad.\n")
    // Settled: another pass changes nothing and imports nothing.
    await pass(store)
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(try text(mirror), "Edited on the iPad.\n")
  }

  func testAMacEditReachesTheMirror() async throws {
    let (store, id, master, mirror) = try await mirroredStore()
    try Data("Edited in the master file.\n".utf8).write(to: master, options: .atomic)
    await store.refreshExternalChanges()
    XCTAssertEqual(store.scripts.first { $0.id == id }?.markdown, "Edited in the master file.\n")
    await pass(store)
    XCTAssertEqual(try text(mirror), "Edited in the master file.\n")
    XCTAssertEqual(store.scripts.count, 1)
  }

  func testAnEditOnBothSidesKeepsTheIPadVersionAsACopy() async throws {
    let (store, id, master, mirror) = try await mirroredStore()
    try Data("Mac side.\n".utf8).write(to: master, options: .atomic)
    await store.refreshExternalChanges()
    try Data("iPad side.\n".utf8).write(to: mirror, options: .atomic)
    await pass(store)
    XCTAssertEqual(try text(mirror), "Mac side.\n")
    XCTAssertEqual(store.scripts.first { $0.id == id }?.markdown, "Mac side.\n")
    let copy = ICloudScripts.folder.appendingPathComponent("Linked (iPad edit).md")
    XCTAssertEqual(try text(copy), "iPad side.\n")
  }
}
