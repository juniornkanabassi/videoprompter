import Foundation

public struct UTF16SourceRange: Codable, Hashable, Sendable {
  public var location: Int
  public var length: Int
  public var upperBound: Int { location + length }
  public init(location: Int, length: Int) {
    precondition(location >= 0 && length >= 0)
    self.location = location
    self.length = length
  }
}

public struct ScriptMetadata: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var fileName: String
  public var createdAt: Date
  public var modifiedAt: Date
  public var revision: UInt64
  public var folderID: UUID?
  public var tags: [String]
  public var contentFingerprint: String
  public init(
    id: UUID = UUID(), title: String, fileName: String, createdAt: Date = Date(),
    modifiedAt: Date = Date(), revision: UInt64 = 0, folderID: UUID? = nil, tags: [String] = [],
    contentFingerprint: String = ""
  ) {
    self.id = id
    self.title = title
    self.fileName = fileName
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.revision = revision
    self.folderID = folderID
    self.tags = tags
    self.contentFingerprint = contentFingerprint
  }
}
public struct ScriptFolder: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct ScriptRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID { metadata.id }
  public var metadata: ScriptMetadata
  public var markdown: String
  public init(metadata: ScriptMetadata, markdown: String) {
    self.metadata = metadata
    self.markdown = markdown
  }
}

public struct ReadingAnchor: Codable, Hashable, Sendable {
  public var scriptID: UUID
  public var revision: UInt64
  public var blockID: UUID
  public var tokenOffset: Int
  public var precedingContext: [String]
  public var followingContext: [String]
  public var guideFraction: Double
  public init(
    scriptID: UUID, revision: UInt64, blockID: UUID, tokenOffset: Int,
    precedingContext: [String] = [], followingContext: [String] = [], guideFraction: Double = 0.35
  ) {
    self.scriptID = scriptID
    self.revision = revision
    self.blockID = blockID
    self.tokenOffset = max(0, tokenOffset)
    self.precedingContext = precedingContext
    self.followingContext = followingContext
    self.guideFraction = min(1, max(0, guideFraction))
  }
}

public struct RecognitionEvent: Hashable, Sendable {
  public var replacementID: String
  public var generation: UInt64
  public var text: String
  public var isFinal: Bool
  public var timestamp: TimeInterval
  public var localeIdentifier: String
  public var audioStart: TimeInterval
  public var audioEnd: TimeInterval
  public init(
    replacementID: String, generation: UInt64, text: String, isFinal: Bool, timestamp: TimeInterval,
    localeIdentifier: String = "und", audioStart: TimeInterval = 0, audioEnd: TimeInterval = 0
  ) {
    self.replacementID = replacementID
    self.generation = generation
    self.text = text
    self.isFinal = isFinal
    self.timestamp = timestamp
    self.localeIdentifier = localeIdentifier
    self.audioStart = audioStart
    self.audioEnd = audioEnd
  }
}

public enum PrompterCoreError: Error, Equatable, Sendable {
  case scriptNotFound(UUID)
  case invalidTitle
  case externalConflict(conflictFile: String)
  case unknownSchema(Int)
  case corruptIndex
  case unsafePath(String)
  case destinationExists
}
