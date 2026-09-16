import Foundation

public enum MarkdownBlockKind: String, Codable, Hashable, Sendable {
  case paragraph, heading, listItem, quote, code, thematicBreak
}
public struct DocumentToken: Codable, Hashable, Sendable {
  public var text: String
  public var normalised: String
  public var sourceRange: UTF16SourceRange
  public var blockID: UUID
}
public struct StageDirection: Codable, Hashable, Sendable {
  public var text: String
  public var sourceRange: UTF16SourceRange
}
public struct MarkdownBlock: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var kind: MarkdownBlockKind
  public var sourceRange: UTF16SourceRange
  public var rawMarkdown: String
  public var spokenTokens: [DocumentToken]
  public var stageDirections: [StageDirection]
}

public struct PrompterDocument: Codable, Hashable, Sendable {
  private static let tokenRegex = try! NSRegularExpression(
    pattern: #"[\p{L}\p{N}][\p{L}\p{N}\p{M}]*(?:['’][\p{L}\p{N}][\p{L}\p{N}\p{M}]*)*"#)
  private static let linkRegex = try! NSRegularExpression(pattern: #"!?\[[^\]\n]+\]\([^\)\n]+\)"#)
  private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]*`"#)
  private static let stageDirectionRegex = try! NSRegularExpression(
    pattern: #"(?<!\\)\[([^\]\n]+)\](?!\s*\()"#)
  public var markdown: String
  public var blocks: [MarkdownBlock]
  public var spokenTokens: [DocumentToken] { blocks.flatMap(\.spokenTokens) }
  public init(markdown: String, previous: PrompterDocument? = nil) {
    self.markdown = markdown
    let drafts = Self.blockDrafts(markdown)
    let ids = Self.reusedIDs(drafts: drafts, previous: previous?.blocks ?? [])
    blocks = zip(drafts, ids).map { draft, id in
      let excluded = Self.excludedRanges(in: draft.text, base: draft.range.location)
      return MarkdownBlock(
        id: id, kind: draft.kind, sourceRange: draft.range, rawMarkdown: draft.text,
        spokenTokens: Self.tokens(
          in: draft.text, base: draft.range.location, excluding: excluded.ranges, blockID: id),
        stageDirections: excluded.cues.map { StageDirection(text: $0.text, sourceRange: $0.range) })
    }
  }
  public static func normalise(_ value: String) -> String {
    // NFC first: decomposed script text (PDF imports) and composed recogniser output fold alike.
    value.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_GB")
    ).replacingOccurrences(of: "’", with: "'").lowercased()
  }
  private struct Draft {
    var kind: MarkdownBlockKind
    var range: UTF16SourceRange
    var text: String
  }
  private static func blockDrafts(_ markdown: String) -> [Draft] {
    let ns = markdown as NSString
    var result: [Draft] = []
    var start: Int?
    var end = 0
    var inFence = false
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    var cursor = 0
    func append(_ lower: Int, _ upper: Int) {
      guard upper > lower else { return }
      let range = NSRange(location: lower, length: upper - lower)
      let text = ns.substring(with: range)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let kind: MarkdownBlockKind
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        kind = .code
      } else if trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil {
        kind = .heading
      } else if trimmed.range(of: #"^(?:[-+*]|\d+[.)])\s"#, options: .regularExpression) != nil {
        kind = .listItem
      } else if trimmed.hasPrefix(">") {
        kind = .quote
      } else if trimmed.range(of: #"^(?:-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
        kind = .thematicBreak
      } else {
        kind = .paragraph
      }
      result.append(Draft(kind: kind, range: UTF16SourceRange(location: lower, length: upper - lower), text: text))
    }
    for (i, sub) in lines.enumerated() {
      let line = String(sub)
      let length = (line as NSString).length
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
      if trimmed.isEmpty && !inFence {
        if let s = start { append(s, end) }
        start = nil
      } else {
        if start == nil { start = cursor }
        end = cursor + length
        if fence { inFence.toggle() }
      }
      cursor += length + (i < lines.count - 1 ? 1 : 0)
    }
    if let s = start { append(s, end) }
    return result
  }
  private static func reusedIDs(drafts: [Draft], previous: [MarkdownBlock]) -> [UUID] {
    var result = drafts.map { _ in UUID() }
    var used = Set<Int>()
    for i in drafts.indices {
      let exact = previous.indices.filter {
        !used.contains($0) && previous[$0].rawMarkdown == drafts[i].text
      }
      if let j = exact.min(by: { abs($0 - i) < abs($1 - i) }) {
        result[i] = previous[j].id
        used.insert(j)
        continue
      }
      let words = Set(similarityTokens(drafts[i].text))
      var candidates: [(Int, Double)] = []
      for j in previous.indices where !used.contains(j) {
        let old = Set(similarityTokens(previous[j].rawMarkdown))
        let unionCount = words.union(old).count
        let overlap = words.intersection(old).count
        let score = unionCount == 0 ? 0.0 : Double(overlap) / Double(unionCount)
        if score >= 0.5 { candidates.append((j, score)) }
      }
      candidates.sort { $0.1 == $1.1 ? abs($0.0 - i) < abs($1.0 - i) : $0.1 > $1.1 }
      if let best = candidates.first,
        candidates.dropFirst().first.map({ best.1 - $0.1 > 0.1 }) ?? true
      {
        result[i] = previous[best.0].id
        used.insert(best.0)
      }
    }
    return result
  }
  private static func similarityTokens(_ text: String) -> [String] {
    tokenMatches(text).map { normalise($0.0.substring(with: $0.1)) }
  }
  private static func tokenMatches(_ text: String) -> [(NSString, NSRange)] {
    let ns = text as NSString
    return tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
      (ns, $0.range)
    }
  }
  private static func tokens(in text: String, base: Int, excluding: [NSRange], blockID: UUID) -> [DocumentToken] {
    tokenMatches(text).compactMap { ns, range in
      guard !excluding.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return nil }
      let value = ns.substring(with: range)
      return DocumentToken(
        text: value, normalised: normalise(value),
        sourceRange: .init(location: base + range.location, length: range.length), blockID: blockID)
    }
  }
  private static func excludedRanges(in text: String, base: Int) -> (
    ranges: [NSRange], cues: [(text: String, range: UTF16SourceRange)]
  ) {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let linkMatches = linkRegex.matches(in: text, range: full)
    let links = linkMatches.map(\.range)
    let code = inlineCodeRegex.matches(in: text, range: full).map(\.range)
    var ranges = code
    var cues: [(String, UTF16SourceRange)] = []
    for match in linkMatches {
      let raw = ns.substring(with: match.range) as NSString
      let marker = raw.range(of: "](")
      if marker.location != NSNotFound {
        let start = match.range.location + marker.location + 1
        ranges.append(NSRange(location: start, length: NSMaxRange(match.range) - start))
      }
    }
    for match in stageDirectionRegex.matches(in: text, range: full)
    where !links.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
      ranges.append(match.range)
      cues.append((ns.substring(with: match.range(at: 1)), .init(location: base + match.range.location, length: match.range.length)))
    }
    return (ranges, cues)
  }
}
