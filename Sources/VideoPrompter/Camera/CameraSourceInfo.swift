@preconcurrency import AVFoundation
import Foundation

/// Identity and format reported by macOS for an input, not the camera behind a capture card.
struct CameraSourceInfo: Equatable {
  enum ConnectionKind: String {
    case builtIn = "Built-in", usbCamera = "USB camera", hdmiCapture = "HDMI capture"
    case iPhone = "iPhone (Continuity)", iPad = "iPad link"

    static func classify(deviceType: String, transportType: Int32, manufacturer: String, modelID: String, name: String) -> Self {
      let text = [deviceType, manufacturer, modelID, name].joined(separator: " ").lowercased()
      if text.contains("ipad") { return .iPad }
      if text.contains("continuity") || text.contains("iphone") { return .iPhone }
      if text.contains("builtin") || text.contains("built-in") || text.contains("facetime") || text.contains("macbook") || transportType == 0x626c746e { return .builtIn }
      let cards = ["cam link", "ultrastudio", "magewell", "decklink", "blackmagic", "aja", "atem", "capture"]
      if cards.contains(where: text.contains) { return .hdmiCapture }
      if ["lumix", "panasonic", "sony", "canon"].contains(where: text.contains) { return .usbCamera }
      if text.contains("usb video") || text.contains("uvc") { return .hdmiCapture }
      return .usbCamera
    }
  }
  var displayName: String
  var connection: ConnectionKind
  var width: Int?
  var height: Int?
  var nominalFrameRate: Double?
  var measuredFrameRate: Double?
  var shotSummary = "Landscape"
  var hardwareName: String?
  var connectionDescription: String {
    guard connection == .hdmiCapture, let hardwareName, hardwareName != displayName else { return connection.rawValue }
    return "\(connection.rawValue): \(hardwareName)"
  }
  init(displayName: String, connection: ConnectionKind, width: Int? = nil, height: Int? = nil, nominalFrameRate: Double? = nil, measuredFrameRate: Double? = nil) {
    self.displayName = displayName; self.connection = connection; self.width = width; self.height = height
    self.nominalFrameRate = nominalFrameRate; self.measuredFrameRate = measuredFrameRate
  }

  init(device: AVCaptureDevice, displayName: String, measuredFrameRate: Double? = nil) {
    let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    let duration = device.activeVideoMinFrameDuration.seconds
    self.init(displayName: displayName, connection: .classify(deviceType: device.deviceType.rawValue, transportType: device.transportType, manufacturer: device.manufacturer, modelID: device.modelID, name: device.localizedName), width: Int(size.width), height: Int(size.height), nominalFrameRate: duration.isFinite && duration > 0 ? 1 / duration : nil, measuredFrameRate: measuredFrameRate)
    hardwareName = device.localizedName
  }

  var formatDescription: String {
    var parts: [String] = []
    if let width, let height { parts.append("\(width) × \(height)") }
    if let rate = measuredFrameRate ?? nominalFrameRate, rate.isFinite, rate > 0 {
      parts.append(String(format: abs(rate.rounded() - rate) < 0.01 ? "%.0fp" : "%.2fp", rate))
    }
    parts.append(connectionDescription)
    return parts.joined(separator: " · ")
  }

  var summary: String {
    var parts = [displayName, connection.rawValue]
    if let width, let height { parts.append("\(width) × \(height)") }
    if let rate = measuredFrameRate ?? nominalFrameRate, rate.isFinite, rate > 0 {
      parts.append(String(format: abs(rate.rounded() - rate) < 0.01 ? "%.0fp" : "%.2fp", rate))
    }
    return parts.joined(separator: " · ")
  }
}

struct CameraFrameRate {
  private(set) var timestamps: [Double] = []
  mutating func add(_ timestamp: Double) {
    guard timestamp.isFinite else { return }
    if let last = timestamps.last, timestamp <= last { timestamps.removeAll() }
    timestamps.append(timestamp)
    if timestamps.count > 60 { timestamps.removeFirst() }
  }
  var value: Double? {
    guard timestamps.count > 1, let first = timestamps.first, let last = timestamps.last, last > first else { return nil }
    return Double(timestamps.count - 1) / (last - first)
  }
}
