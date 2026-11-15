import XCTest
@testable import VideoPrompter
import PrompterCore

/// A script linked to a file outside iCloud Drive gets a mirror in the iCloud folder, kept in
/// step both ways. Runs against a throwaway library, master file and "iCloud Drive".
@MainActor
final class ICloudMirrorTests: XCTestCase {
  private var dirs: [URL] = []
  private let keys = [ICloudScripts.enabledKey, ICloudScripts.mirrorsKey, ICloudScripts.declinedMirrorsKey, ICloudScripts.unlinkPendingKey, ICloudScripts.deletedOnIPadKey]

  override func tearDown() async throws {
    // Stop new passes before removing the disposable cloud directory.
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    await waitForCurrentPass()
    ICloudScripts.cloudDocsOverride = nil
    for url in dirs { try? FileManager.default.removeItem(at: url) }
  }

  private func waitForCurrentPass() async {
    while let pending = ICloudScripts.pass {
      await pending.value
      // The owner clears the shared task after its await resumes.
      await Task.yield()
    }
  }

  private func temp(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    dirs.append(url)
    return url
  }

  private func pass(_ store: AppStore) async {
    await waitForCurrentPass()
    ICloudScripts.lastPass = .distantPast
    await store.syncICloudScripts()
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  /// A store with one script linked to `master.md`, mirrored by a first pass.
  private func mirroredStore() async throws -> (AppStore, UUID, master: URL, mirror: URL) {
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    await waitForCurrentPass()
    ICloudScripts.cloudDocsOverride = try temp("CloudDocs")
    UserDefaults.standard.set(true, forKey: ICloudScripts.enabledKey)
    let root = try temp("vp-lib"), outside = try temp("vp-notes")
    let store = flushedAtTeardown(AppStore(
      arguments: ["test", "--data-directory", root.path],
      defaults: freshDefaults("ICloudMirrorTests")))
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

  func testUnlinkingAMirroredScriptMakesTheMirrorItsICloudFile() async throws {
    let (store, id, _, mirror) = try await mirroredStore()
    _ = try await store.library!.unlink(id)
    await store.reload()
    await pass(store)
    XCTAssertNil(ICloudScripts.mirrors[id])
    XCTAssertEqual(store.scripts.first { $0.id == id }?.metadata.linkedPath, mirror.standardizedFileURL.path)
    // No second file, and nothing imported twice.
    await pass(store)
    XCTAssertEqual(ICloudScripts.files().count, 1)
    XCTAssertEqual(store.scripts.count, 1)
  }

  func testDeletingAMirroredScriptTrashesItsMirrorWithoutReimportingIt() async throws {
    let (store, id, _, mirror) = try await mirroredStore()
    try await store.library!.delete(id)
    await store.reload()
    await pass(store)
    XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.path))
    XCTAssertNil(ICloudScripts.mirrors[id])
    await pass(store)
    XCTAssertTrue(store.scripts.isEmpty)
  }

  /// Deleted on the iPad, then put back from its Recently Deleted: the Mac restores the script
  /// instead of sending the file to the Trash a second time.
  func testAScriptRestoredOnTheIPadIsRestoredHereNotTrashedAgain() async throws {
    let (store, _, _, _) = try await mirroredStore()
    let plain = try await store.library!.create(title: "Plain", markdown: "Kick-off.\n")
    await store.reload()
    await pass(store)
    let file = ICloudScripts.folder.appendingPathComponent("Plain.md")
    XCTAssertEqual(try text(file), "Kick-off.\n")
    // The iPad moves it to Recently Deleted: the script goes to the library's Trash.
    try FileManager.default.removeItem(at: file)
    await pass(store)
    XCTAssertFalse(store.scripts.contains { $0.id == plain.id })
    // ...and restores it to the same place.
    try Data("Kick-off.\n".utf8).write(to: file)
    await pass(store)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the restored file is not trashed again")
    XCTAssertEqual(store.scripts.first { $0.id == plain.id }?.metadata.linkedPath, file.standardizedFileURL.path)
    XCTAssertFalse(store.trash.contains { $0.metadata.id == plain.id })
    // Settled: nothing is imported twice or trashed later.
    await pass(store)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(store.scripts.filter { $0.metadata.title == "Plain" }.count, 1)
    XCTAssertTrue(ICloudScripts.deletedOnIPad.isEmpty)
  }
}
