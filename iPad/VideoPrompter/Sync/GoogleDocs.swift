import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// One document in the signed-in account's Google Drive.
struct GoogleDoc: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let modified: Date?
}

enum GoogleDocsError: LocalizedError {
  case notALink
  case notShared
  case signInFailed(String)
  case http(Int)

  var errorDescription: String? {
    switch self {
    case .notALink: "That is not a Google Docs link. Copy it from the address bar or Share › Copy link."
    case .notShared:
      "Google would not hand that document over without a sign-in. Sign in with Google in this sheet, or set the document's sharing to “Anyone with the link”."
    case .signInFailed(let reason): "Google sign-in did not finish: \(reason)"
    case .http(let code): "Google Drive answered with error \(code). Try again in a moment."
    }
  }
}

/// Brings scripts in from Google Docs, one way: the doc stays the master and the iPad keeps a
/// Markdown copy in the scripts folder, which can be refreshed from the doc later.
///
/// Two routes. A pasted link works with no sign-in for documents shared with "Anyone with the
/// link", through Google's own export address. Signing in with Google (OAuth with PKCE, read-only
/// Drive access) adds browsing and search, and reaches documents shared only with the account,
/// such as a Workspace domain's. Sign-in needs an OAuth client ID in Info.plist under
/// `GoogleClientID`; without one only the link route is offered.
@MainActor final class GoogleDocs: NSObject, ObservableObject {
  static let clientID = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? "")
    .trimmingCharacters(in: .whitespaces)
  static let scope = "https://www.googleapis.com/auth/drive.readonly"
  private static let keychainAccount = "google-refresh-token"

  var canSignIn: Bool { !Self.clientID.isEmpty }
  @Published private(set) var isSignedIn = false
  private var access: (token: String, expiry: Date)?
  private var authSession: ASWebAuthenticationSession?

  override init() {
    super.init()
    isSignedIn = canSignIn && Keychain.read(Self.keychainAccount) != nil
  }

  // MARK: Links

  /// The document ID in a Docs link (`/document/d/<id>/edit`), or a bare ID pasted on its own.
  static func documentID(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = trimmed.range(of: #"/document/(?:u/\d+/)?d/([A-Za-z0-9_-]{20,})"#, options: .regularExpression) {
      let match = trimmed[range]
      return match.components(separatedBy: "/d/").last.map { String($0.prefix { $0 != "/" }) }
    }
    if trimmed.range(of: #"^[A-Za-z0-9_-]{25,}$"#, options: .regularExpression) != nil { return trimmed }
    return nil
  }

  // MARK: Export

  /// The document's title and text as Markdown, through the API when signed in, else through the
  /// public export address.
  func export(_ id: String) async throws -> (title: String, markdown: String) {
    if isSignedIn {
      let token = try await accessToken()
      let meta = try await getJSON("https://www.googleapis.com/drive/v3/files/\(id)?fields=name&supportsAllDrives=true", token: token)
      let title = meta["name"] as? String ?? "Google Doc"
      for type in ["text/markdown", "text/plain"] {
        let url = "https://www.googleapis.com/drive/v3/files/\(id)/export?mimeType=\(type.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
        let (data, response) = try await get(url, token: token)
        if response.statusCode == 200 { return (title, Self.clean(String(decoding: data, as: UTF8.self))) }
        if response.statusCode == 404 || response.statusCode == 403 { throw GoogleDocsError.notShared }
      }
      throw GoogleDocsError.http(400)
    }
    for format in ["md", "txt"] {
      let (data, response) = try await get("https://docs.google.com/document/d/\(id)/export?format=\(format)", token: nil)
      // A document that is not shared publicly answers with Google's sign-in page.
      let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
      if type.contains("text/html") || response.statusCode == 401 || response.statusCode == 403 {
        throw GoogleDocsError.notShared
      }
      guard response.statusCode == 200 else { continue }
      let title = Self.fileName(response.value(forHTTPHeaderField: "Content-Disposition")) ?? "Google Doc"
      return (title, Self.clean(String(decoding: data, as: UTF8.self)))
    }
    throw GoogleDocsError.notShared
  }

  /// Google's Markdown carries pictures as base64 at the end and escapes plain punctuation; a
  /// prompter wants neither. Escapes are left to the renderer, which already reads them.
  static func clean(_ markdown: String) -> String {
    var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    lines.removeAll { $0.hasPrefix("[image") && $0.contains("]: <data:") }
    var text = lines.joined(separator: "\n")
    text = text.replacingOccurrences(of: #"!\[[^\]]*\]\[image\d+\]"#, with: "", options: .regularExpression)
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  /// `filename*=UTF-8''Match%20preview.md` or `filename="Match preview.md"`, without the extension.
  static func fileName(_ disposition: String?) -> String? {
    guard let disposition else { return nil }
    var name: String?
    if let range = disposition.range(of: #"filename\*=UTF-8''[^;]+"#, options: .regularExpression) {
      name = String(disposition[range].dropFirst("filename*=UTF-8''".count)).removingPercentEncoding
    } else if let range = disposition.range(of: #"filename="[^"]+""#, options: .regularExpression) {
      name = String(disposition[range].dropFirst("filename=\"".count).dropLast())
    }
    guard let name, !name.isEmpty else { return nil }
    return (name as NSString).deletingPathExtension
  }

  // MARK: Browsing (signed in)

  /// Docs the account can open, most recently changed first, shared drives included.
  func list(matching search: String) async throws -> [GoogleDoc] {
    let token = try await accessToken()
    var query = "mimeType='application/vnd.google-apps.document' and trashed=false"
    let words = search.trimmingCharacters(in: .whitespaces)
    if !words.isEmpty {
      query += " and name contains '\(words.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
    }
    var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
      URLQueryItem(name: "pageSize", value: "50"),
      URLQueryItem(name: "fields", value: "files(id,name,modifiedTime)"),
      URLQueryItem(name: "corpora", value: "allDrives"),
      URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
      URLQueryItem(name: "supportsAllDrives", value: "true"),
    ]
    let json = try await getJSON(components.url!.absoluteString, token: token)
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (json["files"] as? [[String: Any]] ?? []).compactMap { file in
      guard let id = file["id"] as? String, let name = file["name"] as? String else { return nil }
      return GoogleDoc(id: id, name: name, modified: (file["modifiedTime"] as? String).flatMap(dates.date))
    }
  }

  // MARK: Sign-in

  private var redirectScheme: String {
    // An iOS OAuth client's redirect is its ID reversed: com.googleusercontent.apps.<number-hash>.
    Self.clientID.split(separator: ".").reversed().joined(separator: ".")
  }

  func signIn() async throws {
    let verifier = Self.randomURLSafe(48)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    let redirect = "\(redirectScheme):/oauth2redirect"
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: Self.clientID),
      URLQueryItem(name: "redirect_uri", value: redirect),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: Self.scope),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    let callback: URL = try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: components.url!, callback: .customScheme(redirectScheme)) { url, error in
        if let url { continuation.resume(returning: url) } else {
          continuation.resume(throwing: GoogleDocsError.signInFailed(error?.localizedDescription ?? "cancelled"))
        }
      }
      session.presentationContextProvider = self
      authSession = session
      session.start()
    }
    authSession = nil
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let code = items.first(where: { $0.name == "code" })?.value else {
      throw GoogleDocsError.signInFailed(items.first { $0.name == "error" }?.value ?? "no code returned")
    }
    let tokens = try await postToken([
      "code": code, "client_id": Self.clientID, "redirect_uri": redirect,
      "grant_type": "authorization_code", "code_verifier": verifier,
    ])
    guard let refresh = tokens["refresh_token"] as? String else { throw GoogleDocsError.signInFailed("no refresh token") }
    Keychain.write(refresh, for: Self.keychainAccount)
    remember(tokens)
    isSignedIn = true
  }

  func signOut() {
    Keychain.delete(Self.keychainAccount)
    access = nil
    isSignedIn = false
  }

  private func accessToken() async throws -> String {
    if let access, access.expiry > Date().addingTimeInterval(60) { return access.token }
    guard let refresh = Keychain.read(Self.keychainAccount) else {
      isSignedIn = false
      throw GoogleDocsError.signInFailed("signed out")
    }
    do {
      let tokens = try await postToken(["refresh_token": refresh, "client_id": Self.clientID, "grant_type": "refresh_token"])
      remember(tokens)
    } catch GoogleDocsError.http(400) {
      // Revoked, or expired: Google ends a testing-mode app's sign-in after seven days.
      signOut()
      throw GoogleDocsError.signInFailed("Google ended the sign-in. Sign in again.")
    }
    guard let access else { throw GoogleDocsError.signInFailed("no access token") }
    return access.token
  }

  private func remember(_ tokens: [String: Any]) {
    guard let token = tokens["access_token"] as? String else { return }
    access = (token, Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 3000))
  }

  // MARK: HTTP

  private func get(_ url: String, token: String?) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: url)!)
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, response as! HTTPURLResponse)
  }

  private func getJSON(_ url: String, token: String) async throws -> [String: Any] {
    let (data, response) = try await get(url, token: token)
    if response.statusCode == 404 || response.statusCode == 403 { throw GoogleDocsError.notShared }
    guard response.statusCode == 200 else { throw GoogleDocsError.http(response.statusCode) }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private func postToken(_ form: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
      .joined(separator: "&").data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw GoogleDocsError.http(status) }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private static func randomURLSafe(_ count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes).base64URL
  }
}

extension GoogleDocs: ASWebAuthenticationPresentationContextProviding {
  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      // Sign-in starts from a button on screen, so there is always a window scene.
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      return scenes.lazy.compactMap(\.keyWindow).first ?? ASPresentationAnchor(windowScene: scenes[0])
    }
  }
}

extension Data {
  fileprivate var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// The refresh token lives in the Keychain, on this device only.
private enum Keychain {
  static let service = "com.juniornkanabassi.VideoPrompter.google"

  static func read(_ account: String) -> String? {
    var item: CFTypeRef?
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func write(_ value: String, for account: String) {
    delete(account)
    let item: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemAdd(item as CFDictionary, nil)
  }

  static func delete(_ account: String) {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    SecItemDelete(query as CFDictionary)
  }
}
