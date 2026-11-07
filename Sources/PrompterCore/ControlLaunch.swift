import Foundation

/// Builds a launch request without opening anything. Disposable libraries connect only; their owner launches the copy explicitly.
public enum ControlLaunch {
  public static func executablePath(app: URL) -> String? {
    let contents = app.appendingPathComponent("Contents")
    guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
      let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
      name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
    return contents.appendingPathComponent("MacOS").appendingPathComponent(name).resolvingSymlinksInPath().path
  }

  public static func arguments(appPath: String?, bundleID: String, dataDirectory: String?) throws -> [String] {
    if dataDirectory != nil {
      throw ControlCLI.UsageError(description: "Start a re-identified agent copy with the authorised hidden launcher before using --data-directory.")
    }
    var args = ["-g"]
    if let appPath { args += ["-a", appPath] } else { args += ["-b", bundleID] }
    args += ["--args", "--headless"]
    if bundleID != ControlProtocol.bundleID { args += ["--agent-screen"] }
    return args
  }
}
