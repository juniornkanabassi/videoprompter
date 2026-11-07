import AppKit
import PrompterCore

/// Kept internal-but-testable: rendering and source patching have no SwiftUI dependency.
struct FormattedMarkdownEditModel {
  private final class CachedModel: NSObject {
    let model: FormattedMarkdownEditModel
    init(_ model: FormattedMarkdownEditModel) { self.model = model }
  }
  @MainActor private static let recentModels: NSCache<NSString, CachedModel> = {
    let cache = NSCache<NSString, CachedModel>()
    cache.countLimit = 4
    cache.totalCostLimit = 16 * 1024 * 1024
    return cache
  }()

  /// Revisited content shares immutable parsing only; typography and undo remain per editor.
  @MainActor static func cached(markdown: String) -> FormattedMarkdownEditModel {
    let key = markdown as NSString
    if let cached = recentModels.object(forKey: key) { return cached.model }
    let model = FormattedMarkdownEditModel(markdown: markdown)
    // ponytail: target four ordinary scripts and bypass larger documents;
    // NSCache evicts estimated source/mapping cost and responds to memory pressure.
    if key.length <= 100_000 {
      recentModels.setObject(CachedModel(model), forKey: key, cost: key.length * 32)
    }
    return model
  }

  let markdown: String
  private let renderedSource: NSAttributedString
  private let sourceOffsets: [Int?]
  private let headingRanges: [NSRange]
  /// Rendered callout boxes, for `rendered()` to draw, and their Markdown ranges, for editing.
  private let callouts: [(box: NSRange, title: NSRange, colour: NSColor)]
  private let calloutSources: [NSRange]
  private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(([^)\n]*)\)"#)
  private static let calloutFirstPrefixRegex = try! NSRegularExpression(
    pattern: PrompterDocument.calloutPattern + #"[ \t]*"#)
  private static let calloutContinuationPrefixRegex = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?"#)
  private static let calloutTypeRegex = try! NSRegularExpression(pattern: #"(?<=\[!)\w+"#)
  private static let headingMarkerRegex = try! NSRegularExpression(pattern: #"^#{1,6}\s+"#)
  private static let emptyCalloutLineRegex = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]*$"#)
  private static let listMarkerRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-+*]|\d+[.)])\s+"#)
  private static let orderedListMarkerRegex = try! NSRegularExpression(pattern: #"^\d+[.)]\s"#)

  private static func regexRange(_ regex: NSRegularExpression, in string: String) -> Range<String.Index>? {
    let range = NSRange(location: 0, length: (string as NSString).length)
    guard let match = regex.firstMatch(in: string, range: range),
      let result = Range(match.range, in: string)
    else { return nil }
    return result
  }

  /// `omittingCallouts` leaves callouts and the blank lines around them out of the text
  /// entirely, as the presenter shows it; every other character keeps its Markdown offset.
  init(markdown: String, omittingCallouts: Bool = false) {
    self.markdown = markdown
    let document = PrompterDocument(markdown: markdown)
    let output = NSMutableAttributedString()
    var offsets: [Int?] = []
    var headings: [NSRange] = []
    var boxes: [(box: NSRange, title: NSRange, colour: NSColor)] = []
    var omitted = false
    let source = markdown as NSString
    var cursor = 0

    func isFence(_ line: some StringProtocol) -> Bool {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }
    func appendLiteral(_ range: NSRange) {
      guard range.length > 0 else { return }
      output.append(NSAttributedString(string: source.substring(with: range)))
      offsets += (range.location..<(range.location + range.length)).map(Optional.some)
    }

    for block in document.blocks {
      let isCallout = block.kind == .callout
      if isCallout, omittingCallouts {
        // Skipping the gap before a callout and keeping the one after it leaves one gap
        // between the passages either side, however many callouts sit between them.
        cursor = block.sourceRange.location + block.sourceRange.length
        omitted = true
        continue
      }
      if !(omitted && output.length == 0) {
        appendLiteral(NSRange(location: cursor, length: block.sourceRange.location - cursor))
      }
      let boxStart = output.length
      var title = NSRange(location: boxStart, length: 0)
      var lineOffset = block.sourceRange.location
      let lines = block.rawMarkdown.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() {
        let raw = String(line)
        if block.kind == .code {
          let fence = isFence(raw)
          if !fence {
            let part = NSMutableAttributedString(string: raw)
            part.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: NSRange(location: 0, length: part.length))
            output.append(part)
            offsets += (0..<(raw as NSString).length).map { Optional(lineOffset + $0) }
          }
          lineOffset += (raw as NSString).length
          if index < lines.count - 1 {
            if !fence && !isFence(lines[index + 1]) { output.append(NSAttributedString(string: "\n")); offsets.append(lineOffset) }
            lineOffset += 1
          }
          continue
        }
        // A list line keeps its first marker as written and only the rest is Markdown, so a
        // second number ("3. 2020. A year") stays text instead of becoming a nested list.
        let marker = block.kind == .listItem ? Self.listMarker(in: raw) : nil
        // A callout hides its `> ` prefixes and `[!type]` marker, as Obsidian does.
        let hidden = isCallout ? Self.calloutPrefix(in: raw, first: index == 0) : 0
        let text = marker.map { (raw as NSString).substring(from: NSMaxRange($0.sourceRange)) }
          ?? (raw as NSString).substring(from: hidden)
        let base = lineOffset + (marker.map { NSMaxRange($0.sourceRange) } ?? hidden)
        let rich = (try? AttributedString(markdown: text,
          options: .init(interpretedSyntax: marker == nil && !isCallout ? .full : .inlineOnlyPreservingWhitespace,
            appliesSourcePositionAttributes: true)))
          ?? AttributedString(text)
        let part = NSMutableAttributedString(attributedString: NSAttributedString(rich))
        // Foundation Markdown omits trailing spaces from a paragraph's rendered text.
        // Keep any omitted literal spaces visible and source-mapped while the user is typing.
        let rawTrailingSpaces = text.reversed().prefix { $0 == " " || $0 == "\t" }.count
        let renderedTrailingSpaces = part.string.reversed().prefix { $0 == " " || $0 == "\t" }.count
        if rawTrailingSpaces > renderedTrailingSpaces {
          part.append(NSAttributedString(string: String(text.suffix(rawTrailingSpaces - renderedTrailingSpaces))))
        }
        if let marker {
          output.append(NSAttributedString(string: marker.text))
          offsets += (marker.sourceRange.location..<NSMaxRange(marker.sourceRange)).map { lineOffset + $0 }
        }
        for run in rich.runs {
          let intent = run.inlinePresentationIntent ?? []
          var traits: NSFontTraitMask = []
          if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
          if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
          guard !traits.isEmpty || intent.contains(.code) else { continue }
          let base = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : NSFont.systemFont(ofSize: 14)
          let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
          part.addAttribute(.font, value: font, range: NSRange(run.range, in: rich))
        }
        // It omits leading ones too: without them, Return before a space ("one.| Two") was refused.
        // After the runs above, whose ranges count from the rendered start.
        let rawLeadingSpaces = text.prefix { $0 == " " || $0 == "\t" }.count
        let renderedLeadingSpaces = part.string.prefix { $0 == " " || $0 == "\t" }.count
        if rawLeadingSpaces > renderedLeadingSpaces {
          part.insert(NSAttributedString(string: String(text.prefix(rawLeadingSpaces - renderedLeadingSpaces))), at: 0)
        }
        if rich.runs.contains(where: { run in
          run.presentationIntent?.components.contains(where: { if case .header = $0.kind { return true }; return false }) == true
        }) {
          headings.append(NSRange(location: output.length, length: part.length))
        }
        let partStart = output.length
        output.append(part)
        offsets += Self.sourceOffsets(for: part, source: text, base: base)
        if isCallout, index == 0 {
          if part.length == 0 {
            // No title: show the type, as Obsidian does. It has no Markdown to edit.
            let label = Self.calloutType(in: raw).capitalized
            output.append(NSAttributedString(string: label))
            offsets += Array(repeating: nil, count: (label as NSString).length)
          }
          title = NSRange(location: partStart, length: output.length - partStart)
        }
        lineOffset += (raw as NSString).length
        if index < lines.count - 1 {
          output.append(NSAttributedString(string: "\n"))
          offsets.append(lineOffset)
          lineOffset += 1
        }
      }
      if isCallout {
        boxes.append((NSRange(location: boxStart, length: output.length - boxStart), title,
          Self.calloutColour(Self.calloutType(in: block.rawMarkdown))))
      }
      cursor = block.sourceRange.location + block.sourceRange.length
    }
    appendLiteral(NSRange(location: cursor, length: source.length - cursor))
    renderedSource = output
    sourceOffsets = offsets
    headingRanges = headings
    callouts = boxes
    calloutSources = document.blocks.filter { $0.kind == .callout }.map {
      NSRange(location: $0.sourceRange.location, length: $0.sourceRange.length)
    }
  }

  /// Length of a callout line's hidden prefix: `> [!type]+ ` on the first line, `> ` after it.
  private static func calloutPrefix(in line: String, first: Bool) -> Int {
    let regex = first ? calloutFirstPrefixRegex : calloutContinuationPrefixRegex
    return regexRange(regex, in: line).map { NSRange($0, in: line).length } ?? 0
  }

  private static func calloutType(in text: String) -> String {
    guard let range = regexRange(calloutTypeRegex, in: text) else { return "note" }
    return String(text[range])
  }

  /// Obsidian's colour families; an unknown type is blue, like a note.
  private static func calloutColour(_ type: String) -> NSColor {
    switch type.lowercased() {
    case "tip", "hint", "important", "success", "check", "done": return .systemGreen
    case "warning", "caution", "attention", "question", "help", "faq": return .systemOrange
    case "example": return .systemPurple
    case "abstract", "summary", "tldr": return .systemCyan
    case "danger", "error", "bug", "failure", "fail", "missing": return .systemRed
    case "quote", "cite": return .systemGray
    default: return .systemBlue
    }
  }

  /// NSTextBlock compares by identity, so a fresh one per render would make every keystroke
  /// restyle each callout; the same look reuses the same block. Rendering runs on the main thread.
  nonisolated(unsafe) private static var calloutBoxes: [String: NSTextBlock] = [:]
  private static func calloutBox(_ colour: NSColor, padding: Double, alternate: Bool) -> NSTextBlock {
    let key = "\(colour)|\(padding)|\(alternate)"
    if let box = calloutBoxes[key] { return box }
    let box = NSTextBlock()
    box.setValue(100, type: .percentageValueType, for: .width)
    box.backgroundColor = colour.withAlphaComponent(0.12)
    box.setBorderColor(colour)
    box.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
    box.setWidth(padding, type: .absoluteValueType, for: .padding)
    box.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
    box.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
    calloutBoxes[key] = box
    return box
  }

  /// The callout whose Markdown holds `offset` after its first character, if any.
  private func callout(containing offset: Int) -> NSRange? {
    calloutSources.first { $0.location < offset && offset <= NSMaxRange($0) }
  }

  func applyingStyle(_ delimiter: String, to visibleRange: NSRange) -> FormattedMarkdownEditModel? {
    guard let visibleRange = trimmedStyleRange(visibleRange), let range = sourceRange(for: visibleRange) else { return nil }
    let source = markdown as NSString
    let delimiterLength = (delimiter as NSString).length
    if hasStyle(delimiter, in: visibleRange),
      range.location >= delimiterLength,
      source.substring(with: NSRange(location: range.location - delimiterLength, length: delimiterLength)) == delimiter,
      NSMaxRange(range) + delimiterLength <= source.length,
      source.substring(with: NSRange(location: NSMaxRange(range), length: delimiterLength)) == delimiter
    {
      return replacingSource(
        NSRange(location: range.location - delimiterLength, length: range.length + delimiterLength * 2),
        with: source.substring(with: range))
    }
    return replacingSource(range, with: delimiter + source.substring(with: range) + delimiter)
  }

  private func trimmedStyleRange(_ range: NSRange) -> NSRange? {
    let text = renderedSource.string as NSString
    guard range.location >= 0, range.length >= 0, range.location <= text.length,
      range.length <= text.length - range.location else { return nil }
    var start = range.location
    var end = NSMaxRange(range)
    while start < end, let scalar = UnicodeScalar(text.character(at: start)),
      CharacterSet.whitespacesAndNewlines.contains(scalar)
    { start += 1 }
    while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)),
      CharacterSet.whitespacesAndNewlines.contains(scalar)
    { end -= 1 }
    return start < end ? NSRange(location: start, length: end - start) : nil
  }

  private func hasStyle(_ delimiter: String, in visibleRange: NSRange) -> Bool {
    let trait: NSFontTraitMask = delimiter == "**" ? .boldFontMask : .italicFontMask
    var hasStyle = true
    renderedSource.enumerateAttribute(.font, in: visibleRange) { value, _, _ in
      hasStyle = hasStyle && ((value as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(trait) } ?? false)
    }
    return hasStyle
  }

  func applyingHeading(to visibleRange: NSRange) -> FormattedMarkdownEditModel? {
    guard let range = sourceRange(for: visibleRange) else { return nil }
    let source = markdown as NSString
    let line = source.lineRange(for: range)
    let raw = source.substring(with: line)
    if let marker = Self.regexRange(Self.headingMarkerRegex, in: raw) {
      return replacingSource(NSRange(location: line.location + NSRange(marker, in: raw).location, length: NSRange(marker, in: raw).length), with: "")
    }
    return replacingSource(NSRange(location: line.location, length: 0), with: "# ")
  }

  func isExistingLink(for visibleRange: NSRange) -> Bool {
    guard let range = sourceRange(for: visibleRange) else { return false }
    return linkMatch(containing: range) != nil
  }

  func linkDestination(for visibleRange: NSRange) -> String? {
    guard let range = sourceRange(for: visibleRange), let match = linkMatch(containing: range) else { return nil }
    let destination = (markdown as NSString).substring(with: match.range(at: 2))
    return Self.isSimpleDestination(destination) ? destination : nil
  }

  func applyingLink(to visibleRange: NSRange, destination: String) -> FormattedMarkdownEditModel? {
    let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isSimpleDestination(destination), let selected = sourceRange(for: visibleRange) else { return nil }
    let source = markdown as NSString
    if let match = linkMatch(containing: selected) {
      guard Self.isSimpleDestination(source.substring(with: match.range(at: 2))) else { return nil }
      let label = source.substring(with: match.range(at: 1))
      return replacingSource(match.range, with: "[\(label)](\(destination))")
    }
    return replacingSource(selected, with: "[\(source.substring(with: selected))](\(destination))")
  }

  func removingLink(to visibleRange: NSRange) -> FormattedMarkdownEditModel? {
    guard let selected = sourceRange(for: visibleRange), let match = linkMatch(containing: selected) else { return nil }
    return replacingSource(match.range, with: (markdown as NSString).substring(with: match.range(at: 1)))
  }

  private static func isSimpleDestination(_ value: String) -> Bool {
    !value.contains(where: { $0.isWhitespace || $0.isNewline })
      && URL(string: value)?.scheme != nil
  }

  private func sourceRange(for visibleRange: NSRange) -> NSRange? {
    guard visibleRange.location >= 0, NSMaxRange(visibleRange) <= sourceOffsets.count else { return nil }
    if visibleRange.length == 0 {
      guard let offset = insertionOffsets(at: visibleRange.location).first else { return nil }
      return NSRange(location: offset, length: 0)
    }
    let selected = sourceOffsets[visibleRange.location..<NSMaxRange(visibleRange)]
    guard let first = selected.first ?? nil, selected.allSatisfy({ $0 != nil }),
      let last = selected.last ?? nil, last - first + 1 == selected.count
    else { return nil }
    return NSRange(location: first, length: selected.count)
  }

  private func replacingSource(_ range: NSRange, with replacement: String) -> FormattedMarkdownEditModel? {
    let source = NSMutableString(string: markdown)
    source.replaceCharacters(in: range, with: replacement)
    let next = FormattedMarkdownEditModel(markdown: source as String)
    return next.renderedSource.string == renderedSource.string ? next : nil
  }

  private func linkMatch(containing selection: NSRange) -> NSTextCheckingResult? {
    let source = markdown as NSString
    let full = NSRange(location: 0, length: source.length)
    return Self.linkRegex.matches(in: markdown, range: full).first { match in
      let label = match.range(at: 1)
      return selection.location >= label.location && NSMaxRange(selection) <= NSMaxRange(label)
    }
  }

  /// First visible character at or after a markdown offset, for placing a guide.
  func visibleIndex(forSourceOffset offset: Int) -> Int? {
    sourceOffsets.firstIndex { $0.map { $0 >= offset } ?? false }
  }

  /// The Markdown offset of the rendered character at `index`, or of the next one that has one.
  func sourceOffset(forVisibleIndex index: Int) -> Int? {
    guard index >= 0, index < sourceOffsets.count else { return nil }
    return sourceOffsets[index...].lazy.compactMap { $0 }.first
  }

  /// Markdown offset to rendered index, for the presenter to place spoken tokens and cues in
  /// the same string the editor shows.
  func visibleIndices() -> [Int: Int] {
    var result: [Int: Int] = [:]
    for (index, offset) in sourceOffsets.enumerated() { if let offset { result[offset] = index } }
    return result
  }

  func rendered(fontName: String = "System Serif", fontSize: Double = 14,
    typography: EditorTypography = EditorTypography()) -> NSAttributedString
  {
    let output = NSMutableAttributedString(attributedString: renderedSource)
    let full = NSRange(location: 0, length: output.length)
    guard full.length > 0 else { return output }
    let base = Self.font(name: fontName, size: fontSize)
    output.enumerateAttribute(.font, in: full) { existing, range, _ in
      let prior = existing as? NSFont
      let traits = prior.map { NSFontManager.shared.traits(of: $0) } ?? []
      let family = prior?.fontName.lowercased().contains("mono") == true
        ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : base
      let styled = NSFontManager.shared.convert(family, toHaveTrait: traits)
      output.addAttribute(.font, value: styled, range: range)
    }
    // PresentationIntent is read as a typed Foundation Markdown attribute above.
    // Heading runs have no fixed font size in Foundation, so apply this view's scale here.
    for range in headingRanges where range.length > 0 {
      let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
      output.addAttribute(.font, value: NSFontManager.shared.convert(bold, toSize: fontSize * 1.35), range: range)
    }
    output.addAttribute(.foregroundColor, value: typography.textColor, range: full)
    if typography.lineSpacing > 0 || typography.paragraphSpacing > 0 || typography.alignment != .left {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = typography.lineSpacing
      paragraph.paragraphSpacing = typography.paragraphSpacing
      paragraph.alignment = typography.alignment
      output.addAttribute(.paragraphStyle, value: paragraph, range: full)
    }
    // After the paragraph styles above, which would otherwise replace the box.
    for (index, callout) in callouts.enumerated() where callout.box.length > 0 {
      // Alternating instances keep two touching callouts in two boxes.
      let box = Self.calloutBox(callout.colour, padding: max(6, fontSize * 0.4), alternate: index % 2 == 1)
      output.enumerateAttribute(.paragraphStyle, in: callout.box) { value, range, _ in
        let style = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
        style.textBlocks = [box]
        output.addAttribute(.paragraphStyle, value: style, range: range)
      }
      guard callout.title.length > 0 else { continue }
      output.addAttribute(.foregroundColor, value: typography.textColor, range: callout.title)
      output.enumerateAttribute(.font, in: callout.title) { value, range, _ in
        guard let font = value as? NSFont else { return }
        output.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
      }
    }
    return output
  }

  func replacing(_ range: NSRange, with replacement: String) -> FormattedMarkdownEditModel? {
    guard range.location >= 0, NSMaxRange(range) <= sourceOffsets.count else { return nil }
    if range.length == 0, replacement == "\n", let left = leavingCallout(at: range.location) { return left }
    if range.length == 0 {
      return insertionOffsets(at: range.location).lazy.compactMap {
        replacing([NSRange(location: $0, length: 0)], visibleRange: range, with: replacement)
      }.first
    }
    let selected = sourceOffsets[range.location..<NSMaxRange(range)]
    guard selected.allSatisfy({ $0 != nil }) else { return nil }
    var runs: [NSRange] = []
    for offset in selected.compactMap({ $0 }) {
      if let last = runs.last, offset == NSMaxRange(last) {
        runs[runs.count - 1].length += 1
      } else if runs.last?.location != offset {
        runs.append(NSRange(location: offset, length: 1))
      }
    }
    guard !runs.isEmpty else { return nil }
    return replacing(runs, visibleRange: range, with: replacement)
  }

  private func replacing(_ runs: [NSRange], visibleRange: NSRange, with replacement: String) -> FormattedMarkdownEditModel? {
    let inCode = visibleRange.location < renderedSource.length
      && ((renderedSource.attribute(.font, at: visibleRange.location, effectiveRange: nil) as? NSFont)?.fontName.lowercased().contains("mono") == true)
    let literal: String
    if isListMarkerEdit(runs, replacement: replacement) {
      literal = replacement
    } else if let escaped = Self.literalMarkdown(replacement, inCode: inCode) {
      literal = escaped
    } else {
      return nil
    }
    // Inside a callout a new line stays in it, and a removed line break takes the next line's
    // hidden `> ` with it, so the callout's lines are never split or left with a stray `>`.
    let runs = mergingCalloutPrefixes(runs)
    let literalText = callout(containing: runs[0].location) == nil
      ? literal : literal.replacingOccurrences(of: "\n", with: "\n> ")
    let source = NSMutableString(string: markdown)
    for run in runs.dropFirst().reversed() { source.replaceCharacters(in: run, with: "") }
    source.replaceCharacters(in: runs[0], with: literalText)
    return checked(source as String, replacing: visibleRange, with: replacement)
  }

  /// Source positions may be absent from literal runs. Accept a fallback alignment
  /// only when re-rendering proves it changed exactly the requested visible text.
  private func checked(_ source: String, replacing visibleRange: NSRange, with replacement: String)
    -> FormattedMarkdownEditModel?
  {
    let next = FormattedMarkdownEditModel(markdown: source)
    let expected = NSMutableString(string: renderedSource.string)
    expected.replaceCharacters(in: visibleRange, with: replacement)
    return next.renderedSource.string == expected as String ? next : nil
  }

  /// Return on an empty last line of a callout leaves the callout, as in Obsidian: that `> `
  /// line becomes a blank line and the caret starts a new paragraph below it.
  private func leavingCallout(at index: Int) -> FormattedMarkdownEditModel? {
    let source = markdown as NSString
    for offset in insertionOffsets(at: index) {
      guard let box = callout(containing: offset), offset == NSMaxRange(box) else { continue }
      let lineStart = source.lineRange(for: NSRange(location: offset, length: 0)).location
      let line = NSRange(location: lineStart, length: offset - lineStart)
      guard lineStart > box.location,
        Self.regexRange(Self.emptyCalloutLineRegex, in: source.substring(with: line)) != nil
      else { continue }
      let next = NSMutableString(string: markdown)
      next.replaceCharacters(in: line, with: "\n")
      return checked(next as String, replacing: NSRange(location: index, length: 0), with: "\n")
    }
    return nil
  }

  private func mergingCalloutPrefixes(_ runs: [NSRange]) -> [NSRange] {
    let source = markdown as NSString
    func merged(_ runs: [NSRange]) -> [NSRange] {
      var result: [NSRange] = []
      for run in runs {
        if let last = result.last, NSMaxRange(last) >= run.location {
          result[result.count - 1] = NSUnionRange(last, run)
        } else {
          result.append(run)
        }
      }
      return result
    }
    let lines = merged(runs.map { run in
      let end = NSMaxRange(run)
      // Only a line break between two of the callout's own lines, not the one that ends it.
      guard run.length > 0, source.character(at: end - 1) == 0x0A,
        let box = callout(containing: end - 1), end - 1 < NSMaxRange(box)
      else { return run }
      let rest = source.substring(from: end)
      guard let prefix = Self.regexRange(Self.calloutContinuationPrefixRegex, in: rest) else { return run }
      return NSRange(location: run.location, length: run.length + NSRange(prefix, in: rest).length)
    })
    // A selection covering a callout's whole visible text takes the whole callout, hidden
    // `> [!type]` header and formatting delimiters included.
    var result = lines
    for box in calloutSources {
      let first = sourceOffsets.lazy.compactMap { $0 }.first { $0 >= box.location }
      guard let i = result.firstIndex(where: { $0.location == first && $0.location > box.location }),
        let j = result[i...].firstIndex(where: { NSMaxRange($0) >= NSMaxRange(box) })
      else { continue }
      result.replaceSubrange(i...j, with: [NSRange(location: box.location, length: NSMaxRange(result[j]) - box.location)])
    }
    return merged(result)
  }

  private func isListMarkerEdit(_ runs: [NSRange], replacement: String) -> Bool {
    guard runs.count == 1 else { return false }
    let source = markdown as NSString
    let lineRange = source.lineRange(for: runs[0])
    let line = source.substring(with: lineRange)
    guard let marker = Self.listMarker(in: line) else { return false }
    let local = NSRange(location: runs[0].location - lineRange.location, length: runs[0].length)
    guard local.location >= marker.sourceRange.location, NSMaxRange(local) <= NSMaxRange(marker.sourceRange) else {
      return false
    }
    let amended = NSMutableString(string: line)
    amended.replaceCharacters(in: local, with: replacement)
    return Self.listMarker(in: amended as String) != nil
  }

  private func insertionOffsets(at index: Int) -> [Int] {
    if index == sourceOffsets.count { return [(markdown as NSString).length] }
    guard let next = sourceOffsets[index] else { return [] }
    if index > 0, let previous = sourceOffsets[index - 1], previous + 1 <= next {
      return previous + 1 == next ? [next] : [previous + 1, next]
    }
    return [next]
  }

  private static func sourceOffsets(for rendered: NSAttributedString, source: String, base: Int) -> [Int?] {
    var result = Array<Int?>(repeating: nil, count: rendered.length)
    rendered.enumerateAttribute(.markdownSourcePosition, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
      guard let position = value as? AttributedString.MarkdownSourcePosition,
        let positionRange = NSRange(position, in: source)
      else { return }
      let visible = rendered.attributedSubstring(from: range).string as NSString
      let raw = source as NSString
      let found = raw.range(of: visible as String, options: [], range: positionRange)
      guard found.location != NSNotFound, found.length == range.length else { return }
      for index in 0..<range.length { result[range.location + index] = base + found.location + index }
    }
    // Foundation does not attach positions to every literal run. Align those runs
    // monotonically with their raw UTF-16 source, while source-position anchors keep
    // formatted content on the correct side of hidden delimiters.
    let visible = rendered.string as NSString
    let raw = source as NSString
    var cursor = 0
    for index in result.indices {
      if let offset = result[index] {
        cursor = max(cursor, offset - base + 1)
        continue
      }
      let unit = visible.character(at: index)
      while cursor < raw.length, raw.character(at: cursor) != unit { cursor += 1 }
      guard cursor < raw.length else { continue }
      result[index] = base + cursor
      cursor += 1
    }
    return result
  }

  private static func listMarker(in line: String) -> (text: String, sourceRange: NSRange)? {
    guard let range = regexRange(listMarkerRegex, in: line) else { return nil }
    return (String(line[range]), NSRange(range, in: line))
  }

  private static func literalMarkdown(_ text: String, inCode: Bool) -> String? {
    if inCode { return text.contains("`") ? nil : text }
    var escaped = text
    // Backslash first, so the escapes added after it are not escaped again.
    for character in ["\\", "*", "_", "`", "[", "]", "&", "<"] {
      escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
    }
    return escaped.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      guard let first = line.first else { return String(line) }
      if regexRange(orderedListMarkerRegex, in: String(line)) != nil {
        var value = String(line)
        if let marker = value.firstIndex(where: { $0 == "." || $0 == ")" }) { value.insert("\\", at: marker) }
        return value
      }
      guard "#>+-".contains(first) else { return String(line) }
      return "\\" + line
    }.joined(separator: "\n")
  }

  static func font(name: String, size: Double) -> NSFont {
    switch name {
    case "System Serif":
      let descriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body).withDesign(.serif)
      return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
    case "Monospaced": return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    case "System": return NSFont.systemFont(ofSize: size)
    default: return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }
  }
}
