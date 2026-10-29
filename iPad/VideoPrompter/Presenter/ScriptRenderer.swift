import PrompterCore
import UIKit

/// The presenter's look, as the renderer needs it. Built from PrompterSettings.
struct ScriptStyle: Equatable {
  var fontName = "Lexend Deca"
  var fontSize = 44.0
  var fontWeight = "Regular"
  var textColorHex = "#FFFFFF"
  var textOpacity = 1.0
  var lineSpacing = 0.16
  var paragraphSpacing = 0.34
  var alignment = "Left"
  var showCues = false
  var highlightActiveWord = false

  init(_ settings: PrompterSettings) {
    fontName = settings.fontName
    fontSize = settings.fontSize
    fontWeight = settings.fontWeight
    textColorHex = settings.textColorHex
    textOpacity = settings.textOpacity
    lineSpacing = settings.lineSpacing
    paragraphSpacing = settings.paragraphSpacing
    alignment = settings.alignment
    showCues = settings.showCues
    highlightActiveWord = settings.highlightActiveWord
  }
  init() {}
}

/// Turns a script's Markdown into the presenter's text: Markdown markers hidden, headings bold,
/// callouts left out (they are production notes), and every spoken word's rendered range kept so
/// the presenter can move and colour it. The Mac shows the same words in the same order; only
/// the fine typesetting differs.
enum ScriptRenderer {
  struct Output {
    let text: NSAttributedString
    /// Rendered range of each spoken word with its trailing punctuation, in token order. A word
    /// the rendering does not show has no entry.
    let mappings: [(range: NSRange, token: Int)]
  }

  private static let linkRegex = try! NSRegularExpression(pattern: #"!?\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
  private static let headingRegex = try! NSRegularExpression(pattern: #"^[ \t]*#{1,6}[ \t]+"#)
  private static let quoteRegex = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?"#)

  static func font(_ style: ScriptStyle, scale: Double = 1, bold: Bool = false) -> UIFont {
    let size = CGFloat(style.fontSize * scale)
    let weight: UIFont.Weight = bold || style.fontWeight == "Bold" ? .bold : .regular
    let descriptor = UIFontDescriptor(fontAttributes: [
      .family: style.fontName,
      .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue],
    ])
    let font = UIFont(descriptor: descriptor, size: size)
    // An unknown family falls back to the system font rather than to Times.
    return font.familyName == style.fontName ? font : .systemFont(ofSize: size, weight: weight)
  }

  static func colour(_ hex: String) -> UIColor {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return .white }
    return UIColor(
      red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
      blue: CGFloat(number & 255) / 255, alpha: 1)
  }

  static func render(_ document: PrompterDocument, style: ScriptStyle) -> Output {
    let output = NSMutableAttributedString()
    /// Rendered index of each source character that is shown.
    var visible: [Int: Int] = [:]
    let base = colour(style.textColorHex).withAlphaComponent(style.textOpacity)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = max(3, style.fontSize * style.lineSpacing)
    paragraph.paragraphSpacing = max(10, style.fontSize * style.paragraphSpacing)
    paragraph.alignment = style.alignment == "Right" ? .right : style.alignment == "Center" ? .center : .left
    let bodyFont = font(style)
    let headingFont = font(style, scale: 1.15, bold: true)
    let codeFont = UIFont.monospacedSystemFont(ofSize: CGFloat(style.fontSize * 0.8), weight: .regular)
    var blockRanges: [UUID: NSRange] = [:]

    for block in document.blocks where block.kind != .callout && block.kind != .thematicBreak {
      if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
      let start = output.length
      let blockFont = block.kind == .heading ? headingFont : block.kind == .code ? codeFont : bodyFont
      var text = ""
      var offsets: [Int] = []
      var lineStart = block.sourceRange.location
      let lines = block.rawMarkdown.split(separator: "\n", omittingEmptySubsequences: false)
      var wroteLine = false
      for line in lines {
        let raw = String(line)
        let length = (raw as NSString).length
        defer { lineStart += length + 1 }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if block.kind == .code, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { continue }
        if wroteLine {
          // A line break inside a passage keeps it one paragraph, as the Mac shows it.
          text += "\u{2028}"
          offsets.append(-1)
        }
        wroteLine = true
        var skip = 0
        if block.kind == .heading { skip = match(headingRegex, raw) }
        if block.kind == .quote { skip = match(quoteRegex, raw) }
        if block.kind == .code {
          append(raw, from: 0, lineStart: lineStart, literal: true, into: &text, offsets: &offsets)
        } else {
          append(raw, from: skip, lineStart: lineStart, literal: false, into: &text, offsets: &offsets)
        }
      }
      output.append(NSAttributedString(string: text, attributes: [
        .font: blockFont, .foregroundColor: base, .paragraphStyle: paragraph,
      ]))
      // Offsets count UTF-16 units, as NSString and the document's source ranges do.
      for (index, sourceOffset) in offsets.enumerated() where sourceOffset >= 0 {
        visible[sourceOffset] = start + index
      }
      blockRanges[block.id] = NSRange(location: start, length: output.length - start)
    }

    let plain = output.string as NSString
    // Stage directions such as [pause]: dimmed when shown, squeezed to nothing when not.
    for block in document.blocks {
      for cue in block.stageDirections {
        guard let range = rendered(cue.sourceRange, visible: visible) else { continue }
        if style.showCues {
          output.addAttribute(.foregroundColor, value: base.withAlphaComponent(style.textOpacity * 0.42), range: range)
        } else {
          var hidden = range
          if NSMaxRange(range) < plain.length, plain.character(at: NSMaxRange(range)) == 32 { hidden.length += 1 }
          output.addAttributes([.font: UIFont.systemFont(ofSize: 0.1), .foregroundColor: UIColor.clear, .kern: 0], range: hidden)
        }
      }
    }

    var mappings: [(range: NSRange, token: Int)] = []
    for (index, token) in document.spokenTokens.enumerated() {
      guard blockRanges[token.blockID] != nil, let found = rendered(token.sourceRange, visible: visible)
      else { continue }
      mappings.append((punctuationRange(after: found, in: plain), index))
    }
    return Output(text: output, mappings: mappings)
  }

  private static func match(_ regex: NSRegularExpression, _ line: String) -> Int {
    regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range.length ?? 0
  }

  /// Copies a line, dropping inline Markdown (emphasis markers, code ticks, escapes and link
  /// targets) and recording where each kept character came from.
  private static func append(
    _ raw: String, from skip: Int, lineStart: Int, literal: Bool,
    into text: inout String, offsets: inout [Int]
  ) {
    let ns = raw as NSString
    var links: [Int: (textRange: NSRange, end: Int)] = [:]
    if !literal {
      for match in linkRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
        links[match.range.location] = (match.range(at: 1), NSMaxRange(match.range))
      }
    }
    func isWordCharacter(_ index: Int) -> Bool {
      guard index >= 0, index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
      return CharacterSet.alphanumerics.contains(scalar)
    }
    var i = skip
    while i < ns.length {
      let unit = ns.character(at: i)
      if !literal {
        if let link = links[i] {
          for j in link.textRange.location..<NSMaxRange(link.textRange) {
            text += ns.substring(with: NSRange(location: j, length: 1))
            offsets.append(lineStart + j)
          }
          i = link.end
          continue
        }
        switch unit {
        case 92 where i + 1 < ns.length:  // backslash escape: keep the next character only
          i += 1
          text += ns.substring(with: NSRange(location: i, length: 1))
          offsets.append(lineStart + i)
          i += 1
          continue
        case 42, 96:  // * and `
          i += 1
          continue
        case 126 where i + 1 < ns.length && ns.character(at: i + 1) == 126:  // ~~
          i += 2
          continue
        case 95 where !(isWordCharacter(i - 1) && isWordCharacter(i + 1)):  // _ as emphasis
          i += 1
          continue
        default: break
        }
      }
      text += ns.substring(with: NSRange(location: i, length: 1))
      offsets.append(lineStart + i)
      i += 1
    }
  }

  /// The rendered range covering a source range, when both its ends are shown.
  private static func rendered(_ source: UTF16SourceRange, visible: [Int: Int]) -> NSRange? {
    guard source.length > 0, let start = visible[source.location],
      let end = visible[source.location + source.length - 1], end >= start
    else { return nil }
    return NSRange(location: start, length: end - start + 1)
  }

  private static func punctuationRange(after range: NSRange, in text: NSString) -> NSRange {
    var end = NSMaxRange(range)
    while end < text.length, let scalar = UnicodeScalar(text.character(at: end)),
      CharacterSet.punctuationCharacters.contains(scalar)
    { end += 1 }
    return NSRange(location: range.location, length: end - range.location)
  }
}
