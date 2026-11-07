import CoreTransferable
import Foundation
import PrompterCore
import UniformTypeIdentifiers

/// A fresh file per transfer keeps exports with matching titles independent.
struct ScriptFile: Transferable {
  let script: ScriptRecord

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .init(filenameExtension: "md")!) { item in
      SentTransferredFile(try item.export())
    }
  }

  func export(in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = script.metadata.title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
      .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    var filename = name.isEmpty ? "Untitled Script" : name
    while filename.utf8.count > 240 { filename.removeLast() }
    let url = folder.appendingPathComponent(filename + ".md")
    try script.markdown.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}

/// Scene storage contains identifiers only; unavailable scripts fall back to the current scope.
struct LibrarySceneSelection {
  let scriptID: String
  let scope: String

  @MainActor func restore(in store: AppStore) {
    let folderID = UUID(uuidString: scope).flatMap { id in store.folders.contains { $0.id == id } ? id : nil }
    store.selectFolder(folderID)
    if let id = UUID(uuidString: scriptID), store.visible.contains(where: { $0.id == id }) {
      store.selectedID = id
    }
  }
}
