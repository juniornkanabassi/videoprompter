import AppKit
import Foundation
import PDFKit

public struct ImportPreview: Sendable {
  public let sourceURL: URL
  public let markdown: String
  public let warnings: [String]
  public init(sourceURL: URL, markdown: String, warnings: [String] = []) {
    self.sourceURL = sourceURL
    self.markdown = markdown
    self.warnings = warnings
  }
}
public enum DocumentImportError: Error, LocalizedError, Sendable {
  case fileTooLarge(Int64)
  case unsupportedType(String)
  case unreadableFile, emptyDocument, scannedPDF
  case tooManyPages(Int)
  public var errorDescription: String? {
    switch self {
    case .fileTooLarge(let n): return "This file is \(n) bytes; imports are limited to 20 MB."
    case .unsupportedType(let t): return "Unsupported document type: \(t)."
    case .unreadableFile: return "The document could not be decoded."
    case .emptyDocument: return "The document contains no readable text."
    case .scannedPDF: return "This PDF contains no text layer. OCR is not run during import."
    case .tooManyPages(let n): return "This PDF has \(n) pages; imports are limited to 200 pages."
    }
  }
}
public struct DocumentImporter: Sendable {
  public static let maxBytes: Int64 = 20 * 1024 * 1024
  public static let maxPDFPages = 200
  public init() {}
  public func preview(url: URL) async throws -> ImportPreview {
    let v = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = v.fileSize else { throw DocumentImportError.unreadableFile }
    guard Int64(size) <= Self.maxBytes else { throw DocumentImportError.fileTooLarge(Int64(size)) }
    switch url.pathExtension.lowercased() {
    case "md", "markdown", "txt": return try text(url)
    case "rtf": return try rich(url, .rtf)
    case "docx": return try rich(url, .officeOpenXML)
    case "pdf": return try pdf(url)
    default: throw DocumentImportError.unsupportedType(url.pathExtension)
    }
  }
  private func text(_ u: URL) throws -> ImportPreview {
    let d = try Data(contentsOf: u)
    guard
      let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .utf16) ?? String(
        data: d, encoding: .utf16LittleEndian) ?? String(data: d, encoding: .utf16BigEndian),
      !s.isEmpty
    else { throw DocumentImportError.unreadableFile }
    return ImportPreview(sourceURL: u, markdown: s)
  }
  private func rich(_ u: URL, _ type: NSAttributedString.DocumentType) throws -> ImportPreview {
    let d = try Data(contentsOf: u)
    guard
      let a = try? NSAttributedString(
        data: d, options: [.documentType: type], documentAttributes: nil),
      !a.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw DocumentImportError.unreadableFile }
    return ImportPreview(
      sourceURL: u, markdown: a.string, warnings: ["Formatting was reduced to plain Markdown text."]
    )
  }
  private func pdf(_ u: URL) throws -> ImportPreview {
    guard let p = PDFDocument(url: u) else { throw DocumentImportError.unreadableFile }
    guard p.pageCount <= Self.maxPDFPages else {
      throw DocumentImportError.tooManyPages(p.pageCount)
    }
    var out: [String] = []
    for i in 0..<p.pageCount { if let s = p.page(at: i)?.string, !s.isEmpty { out.append(s) } }
    guard !out.isEmpty else { throw DocumentImportError.scannedPDF }
    return ImportPreview(
      sourceURL: u, markdown: out.joined(separator: "\n\n"),
      warnings: p.pageCount == out.count ? [] : ["Some pages have no text layer and were skipped."])
  }
}
