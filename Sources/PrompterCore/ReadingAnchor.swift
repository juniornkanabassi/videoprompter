import Foundation

public enum AnchorRemapDisposition: String, Codable, Sendable {
  case exact, context, nearestPrevious, nearestFollowing, currentPassageDeleted, documentEmpty
}
public struct AnchorRemapResult: Sendable {
  public var anchor: ReadingAnchor?
  public var disposition: AnchorRemapDisposition
}

public enum ReadingAnchorRemapper {
  public static func makeAnchor(
    scriptID: UUID, revision: UInt64, document: PrompterDocument, globalTokenIndex: Int,
    guideFraction: Double = 0.35
  ) -> ReadingAnchor? {
    let tokens = document.spokenTokens
    guard !tokens.isEmpty else { return nil }
    let index = min(max(0, globalTokenIndex), tokens.count - 1)
    let token = tokens[index]
    let blockTokens = document.blocks.first(where: { $0.id == token.blockID })?.spokenTokens ?? []
    let offset = blockTokens.firstIndex(where: { $0.sourceRange == token.sourceRange }) ?? 0
    return ReadingAnchor(
      scriptID: scriptID, revision: revision, blockID: token.blockID, tokenOffset: offset,
      precedingContext: Array(tokens[max(0, index - 3)..<index].map(\.normalised)),
      followingContext: Array(tokens[(index + 1)..<min(tokens.count, index + 4)].map(\.normalised)),
      guideFraction: guideFraction)
  }

  public static func globalIndex(of anchor: ReadingAnchor, in document: PrompterDocument) -> Int? {
    var base = 0
    for block in document.blocks {
      if block.id == anchor.blockID, !block.spokenTokens.isEmpty {
        return base + min(anchor.tokenOffset, block.spokenTokens.count - 1)
      }
      base += block.spokenTokens.count
    }
    return nil
  }

  public static func remap(
    _ anchor: ReadingAnchor, from old: PrompterDocument, to new: PrompterDocument,
    newRevision: UInt64
  ) -> AnchorRemapResult {
    guard !new.spokenTokens.isEmpty else { return .init(anchor: nil, disposition: .documentEmpty) }
    if let block = new.blocks.first(where: { $0.id == anchor.blockID }),
      !block.spokenTokens.isEmpty,
      let oldBlock = old.blocks.first(where: { $0.id == anchor.blockID })
    {
      let localMap = lcsMap(
        oldBlock.spokenTokens.map(\.normalised), block.spokenTokens.map(\.normalised))
      // The word left its block (a paragraph split or merge): follow it through the whole document.
      if localMap[anchor.tokenOffset] == nil,
        let moved = contextMatch(anchor, in: new, newRevision: newRevision)
      {
        return moved
      }
      let exactOffset: Int
      if let mapped = localMap[anchor.tokenOffset] {
        exactOffset = mapped
      } else if let previous = localMap.keys.filter({ $0 < anchor.tokenOffset }).max(),
        let mapped = localMap[previous]
      {
        exactOffset = min(block.spokenTokens.count - 1, mapped + anchor.tokenOffset - previous)
      } else if let following = localMap.keys.filter({ $0 > anchor.tokenOffset }).min(),
        let mapped = localMap[following]
      {
        exactOffset = mapped
      } else {
        exactOffset = min(anchor.tokenOffset, block.spokenTokens.count - 1)
      }
      let blockStart = new.blocks.prefix(while: { $0.id != block.id }).reduce(0) { $0 + $1.spokenTokens.count }
      return moved(anchor, to: blockStart + exactOffset, in: new, newRevision, localMap[anchor.tokenOffset] == nil ? .context : .exact)
    }
    let oldIndex = globalIndex(of: anchor, in: old) ?? 0
    let oldWords = old.spokenTokens.map(\.normalised)
    let newWords = new.spokenTokens.map(\.normalised)
    if let moved = contextMatch(anchor, in: new, newRevision: newRevision) { return moved }
    let mapping = lcsMap(oldWords, newWords)
    if let prior = mapping.keys.filter({ $0 < oldIndex }).max(), let mapped = mapping[prior] {
      return moved(anchor, to: min(newWords.count - 1, mapped + 1), in: new, newRevision, .currentPassageDeleted)
    }
    if let next = mapping.keys.filter({ $0 > oldIndex }).min(), let mapped = mapping[next] {
      return moved(anchor, to: mapped, in: new, newRevision, .nearestFollowing)
    }
    let proportional = min(
      newWords.count - 1, Int(Double(oldIndex) / Double(max(1, oldWords.count)) * Double(newWords.count)))
    return moved(anchor, to: proportional, in: new, newRevision, .currentPassageDeleted)
  }

  /// The anchor rebuilt at `index` of `new`, with its script and guide kept.
  private static func moved(
    _ anchor: ReadingAnchor, to index: Int, in new: PrompterDocument, _ newRevision: UInt64,
    _ disposition: AnchorRemapDisposition
  ) -> AnchorRemapResult {
    .init(
      anchor: makeAnchor(
        scriptID: anchor.scriptID, revision: newRevision, document: new, globalTokenIndex: index,
        guideFraction: anchor.guideFraction),
      disposition: disposition)
  }

  /// The one place in `new` whose neighbours match the anchor's saved context, if it is unique.
  private static func contextMatch(
    _ anchor: ReadingAnchor, in new: PrompterDocument, newRevision: UInt64
  ) -> AnchorRemapResult? {
    guard anchor.precedingContext.count + anchor.followingContext.count >= 2 else { return nil }
    let newWords = new.spokenTokens.map(\.normalised)
    let candidates = newWords.indices.filter { i in
      let before = Array(newWords[max(0, i - anchor.precedingContext.count)..<i])
      let after = Array(
        newWords[(i + 1)..<min(newWords.count, i + 1 + anchor.followingContext.count)])
      return before == Array(anchor.precedingContext.suffix(before.count))
        && after == Array(anchor.followingContext.prefix(after.count))
        && before.count + after.count >= 2
    }
    guard candidates.count == 1 else { return nil }
    return moved(anchor, to: candidates[0], in: new, newRevision, .context)
  }

  private static func lcsMap(_ a: [String], _ b: [String]) -> [Int: Int] {
    guard !a.isEmpty && !b.isEmpty else { return [:] }
    var positions: [String: [Int]] = [:]
    for (index, word) in b.enumerated() { positions[word, default: []].append(index) }
    var result: [Int: Int] = [:]
    var next = 0
    for (index, word) in a.enumerated() {
      guard let options = positions[word], let matched = options.first(where: { $0 >= next }) else {
        continue
      }
      result[index] = matched
      next = matched + 1
    }
    return result
  }
}
