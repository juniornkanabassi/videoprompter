@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// A video device as the picker shows it. `uid` is `AVCaptureDevice.uniqueID`, which is what
/// gets remembered: names repeat across identical cameras, unique IDs do not.
struct CameraDevice: Identifiable, Hashable, Sendable {
  let uid: String
  let originalName: String
  var isPhysical = true
  var nickname: String? = nil
  var name: String { nickname ?? originalName }
  init(uid: String, name: String, isPhysical: Bool = true, nickname: String? = nil) {
    self.uid = uid; self.originalName = name; self.isPhysical = isPhysical; self.nickname = nickname
  }
  var id: String { uid }
}

/// What the presenter shows. Older versions stored only whether video was on, as a Bool.
enum PresenterDisplayMode: String, Codable, CaseIterable, Identifiable {
  case prompterOnly, prompterWithVideo, videoOnly
  var id: String { rawValue }
  var label: String {
    switch self {
    case .prompterOnly: "Script only"
    case .prompterWithVideo: "Script and camera"
    case .videoOnly: "Camera view"
    }
  }
  var systemImage: String {
    switch self {
    case .prompterOnly: "text.alignleft"
    case .prompterWithVideo: "video.fill"
    case .videoOnly: "camera.fill"
    }
  }
}

@MainActor final class CameraModel: ObservableObject {
  /// One model for the Second monitor window, the Camera menu and the presenter's video background:
  /// they show the same camera with the same rotation and the same guides.
  static let shared = CameraModel(defaults: AppStore.preferences())
  @Published private(set) var devices: [CameraDevice] = []
  @Published private var storedSelectedUID: String?
  var selectedUID: String? {
    get { storedSelectedUID }
    set {
      guard !recordingLocked, newValue != storedSelectedUID else { return }
      let transferringGuides = pendingGuides != nil && newValue != nil
      storedSelectedUID = newValue
      framingGuidesBypassed = false
      if let pendingGuides, newValue != nil {
        self.pendingGuides = nil
        guides = pendingGuides
        guideStore.set(guides, for: newValue)
      } else {
        loadingGuides = true
        guides = guideStore.guides(for: newValue)
        loadingGuides = false
      }
      defaults.set(newValue, forKey: "cameraDeviceUID")
      if transferringGuides { guideStore.clearPendingGuides() }
    }
  }
  @Published private var storedGuides = CameraGuides()
  var guides: CameraGuides {
    get { storedGuides }
    set {
      var value = newValue
      if let marker = value.marker, !marker.isValid { value.marker = storedGuides.marker }
      if recordingLocked {
        value.rotation = storedGuides.rotation
        value.automaticRotation = storedGuides.automaticRotation
      }
      value.sanitise()
      let old = storedGuides
      // Keep unresolved choices until discovery (or an explicit choice) supplies a camera.
      if !loadingGuides && selectedUID == nil {
        pendingGuides = value
        guideStore.set(value, for: nil)
      }
      guard value != old else { return }
      if !loadingGuides, (value.zebras && !old.zebras) || (value.falseColour && !old.falseColour) {
        exposureBypassed = false
      }
      if !loadingGuides, (value.thirds && !old.thirds) || (value.axes && !old.axes) || (value.bullseye && !old.bullseye) || (value.marker != nil && value.marker != old.marker) {
        framingGuidesBypassed = false
      }
      storedGuides = value
      if !loadingGuides {
        guideStore.set(value, for: selectedUID)
        if value.zebras != old.zebras { announceExposure(ExposureLegend.zebraTitle(for: value.validatedZebraPurpose), on: value.zebras) }
        if value.falseColour != old.falseColour { announceExposure("Check brightness · False colour", on: value.falseColour) }
      }
    }
  }
  @Published var mirrored: Bool { didSet {
    defaults.set(mirrored, forKey: "cameraMirrored")
  } }
  var recorder: CameraRecorder = .shared
  var recordingLocked: Bool { recorder.isRecording || recorder.isBusy }
  @Published var cleanView = false
  @Published var exposureBypassed = false
  var exposureIsConfigured: Bool { guides.zebras || guides.falseColour }
  @Published var framingGuidesBypassed = false
  var framingIsConfigured: Bool { guides.thirds || guides.axes || guides.bullseye || guides.marker != nil }
  var framingIsVisible: Bool { framingIsConfigured && !framingGuidesBypassed && !cleanView }
  /// Presenter-effective state: includes both temporary bypass and Clean view.
  var effectiveFalseColour: Bool { previewGuides.falseColour }
  var effectiveZebras: Bool { previewGuides.zebras }
  var effectiveGuides: CameraGuides { previewGuides }

  /// Shared controls retain stored settings while explicit choices restore visibility.
  var exposureControls: Binding<CameraGuides> {
    Binding(get: { self.guides }, set: { value in
      let disabling = (self.guides.falseColour && !value.falseColour)
        || (self.guides.zebras && !value.zebras)
      self.guides = value
      if !disabling { self.exposureBypassed = false; self.cleanView = false }
    })
  }
  func changeExposure(_ change: (inout CameraGuides) -> Void) {
    var value = guides
    value.changeExposure(change)
    guides = value
    exposureBypassed = false; cleanView = false
  }
  func zebraBinding<T>(_ key: WritableKeyPath<CameraGuides, T>) -> Binding<T> {
    Binding(get: { self.guides[keyPath: key] }, set: { value in
      self.changeExposure { $0[keyPath: key] = value; $0.zebras = true }
    })
  }
  func chooseZebraPreset(_ purpose: CameraGuides.ZebraPurpose) {
    changeExposure { $0.useZebraPreset(purpose); $0.zebras = true }
  }
  func setGreyCardCheck(_ enabled: Bool) {
    guides.greyCardCheck = enabled
    if enabled { exposureBypassed = false; cleanView = false }
  }
  func chooseGuide(_ change: (inout CameraGuides) -> Void) {
    change(&guides)
    framingGuidesBypassed = false; cleanView = false
  }
  func chooseFrameMarker(_ marker: CameraAspect?) {
    guard marker?.isValid != false else { return }
    chooseGuide { $0.marker = marker }
  }
  func toggleFramingGuides() {
    if framingIsVisible { framingGuidesBypassed = true }
    else {
      if !framingIsConfigured { guides.thirds = true }
      framingGuidesBypassed = false; cleanView = false
    }
    announceExposure("Framing guides", on: framingIsVisible)
  }
  func togglePictureExposureCheck() {
    if !exposureIsConfigured { guides.falseColour = true; cleanView = false }
    else { toggleExposureCheck() }
  }
  var monitorGuides: CameraGuides {
    var value = guides
    if exposureBypassed { value.zebras = false; value.falseColour = false }
    return value
  }
  var previewGuides: CameraGuides {
    var value = monitorGuides
    if cleanView { value.zebras = false; value.falseColour = false }
    if cleanView || framingGuidesBypassed { value.thirds = false; value.axes = false; value.bullseye = false; value.marker = nil }
    return value
  }
  var exposureCheckState: String {
    if cleanView { return "Hidden in Clean view" }
    if !exposureIsConfigured { return "Off" }
    return exposureBypassed ? "Aids bypassed" : "Aids visible"
  }
  func exposureBinding(_ key: WritableKeyPath<CameraGuides, Bool>, presenter: Bool = true) -> Binding<Bool> {
    Binding(get: { (presenter ? self.previewGuides : self.monitorGuides)[keyPath: key] }, set: { enabled in
      if enabled { self.exposureBypassed = false; if presenter { self.cleanView = false } }
      self.guides.changeExposure { $0[keyPath: key] = enabled }
    })
  }
  func toggleExposureCheck() {
    guard exposureIsConfigured else { return }
    if cleanView || exposureBypassed { restoreExposureAids() }
    else { exposureBypassed = true; announceExposure("Exposure aids bypassed", on: false) }
  }
  func restoreExposureAids() {
    guard exposureIsConfigured else { return }
    cleanView = false; exposureBypassed = false
    announceExposure("Exposure aids restored", on: true)
  }
  static let cleanViewExplanation = "Shows only the camera picture in the presenter. Move the pointer to reveal controls, or press Option-Command-K to leave Clean view. Your monitoring aids are restored when Clean is off. The Second monitor window keeps its overlays."

  private func announceExposure(_ name: String, on: Bool) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: name + (on ? " on" : " off"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }
  func applySkinExposurePreset() {
    chooseZebraPreset(.faceReference)
    guides.falseColour = false
  }
  @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "cameraAlwaysOnTop") } }
  /// Script only, script over the live picture, or the live picture alone. The presenter's own
  /// controls are unaffected. The old Bool key is still written, so an older build reads it too.
  @Published var displayMode: PresenterDisplayMode {
    didSet {
      guard !showingTemporarily else { return }
      defaults.set(displayMode.rawValue, forKey: "presenterDisplayMode")
      defaults.set(displayMode != .prompterOnly, forKey: "presenterWithVideo")
    }
  }
  private var showingTemporarily = false
  /// True while `showTemporarily` assigns, which is when `$displayMode` subscribers hear of it.
  var isShowingTemporarily: Bool { showingTemporarily }
  /// Camera only forced by the reference monitor or a presenter with no script. It is not saved,
  /// so a quit or a close leaves the person's own choice for next time.
  func showTemporarily(_ mode: PresenterDisplayMode) {
    showingTemporarily = true
    displayMode = mode
    showingTemporarily = false
  }
  /// The last view the person chose, as saved.
  var savedDisplayMode: PresenterDisplayMode {
    defaults.string(forKey: "presenterDisplayMode").flatMap(PresenterDisplayMode.init)
      ?? (defaults.bool(forKey: "presenterWithVideo") ? .prompterWithVideo : .prompterOnly)
  }
  func restoreSavedDisplayMode() {
    let saved = savedDisplayMode
    if displayMode != saved { displayMode = saved }
  }
  /// Whether the picture is shown at all: the capsule button, the menu and the camera ask this.
  var presentsWithVideo: Bool {
    get { displayMode != .prompterOnly }
    set { if newValue != presentsWithVideo { displayMode = newValue ? .prompterWithVideo : .prompterOnly } }
  }
  var recordingReadyOverride: Bool?
  @Published var authorization = AVCaptureDevice.authorizationStatus(for: .video)
  var pictureSizeOverride: CGSize?
  var pictureSize: CGSize? { pictureSizeOverride ?? SharedCameraSession.shared.pictureSize }
  @Published private(set) var nicknames: [String: String] = [:]
  func renameCamera(_ uid: String, to name: String) {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    nicknames[uid] = value.isEmpty ? nil : value
    defaults.set(nicknames, forKey: "cameraNicknames")
    devices = devices.map { device in var d = device; d.nickname = nicknames[d.uid]; return d }
  }
  var sourceInfo: CameraSourceInfo? {
    guard let uid = SharedCameraSession.shared.attachedUID, let device = AVCaptureDevice(uniqueID: uid) else { return nil }
    var info = CameraSourceInfo(device: device, displayName: nicknames[uid] ?? device.localizedName, measuredFrameRate: SharedCameraSession.shared.measuredFrameRate)
    info.shotSummary = shotSummary
    return info
  }
  var shotSummary: String {
    if guides.automaticRotation { return "Automatic" }
    switch guides.rotation {
    case .none: return "Landscape"
    case .quarter: return "Turned left for vertical"
    case .threeQuarters: return "Turned right for vertical"
    case .half: return "Upside down"
    }
  }
  private let defaults: UserDefaults
  private let guideStore: CameraGuideStore
  private var loadingGuides = false
  private var pendingGuides: CameraGuides?
  // nonisolated so `deinit` can take the observers back out again.
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
  nonisolated(unsafe) private var pictureSizeObserver: NSObjectProtocol?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    nicknames = defaults.dictionary(forKey: "cameraNicknames") as? [String: String] ?? [:]
    guideStore = CameraGuideStore(defaults: defaults)
    let uid = defaults.string(forKey: "cameraDeviceUID")
    storedSelectedUID = uid
    storedGuides = guideStore.guides(for: uid)
    if uid == nil { pendingGuides = guideStore.savedGuides(for: nil) }
    mirrored = defaults.bool(forKey: "cameraMirrored")
    alwaysOnTop = defaults.bool(forKey: "cameraAlwaysOnTop")
    displayMode = defaults.string(forKey: "presenterDisplayMode").flatMap(PresenterDisplayMode.init)
      ?? (defaults.bool(forKey: "presenterWithVideo") ? .prompterWithVideo : .prompterOnly)
    // Output summaries read the delivered size, which can change without a camera setting changing.
    pictureSizeObserver = NotificationCenter.default.addObserver(
      forName: .cameraPictureSizeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    if let pictureSizeObserver { NotificationCenter.default.removeObserver(pictureSizeObserver) }
  }

  /// A rotation chosen by hand turns Auto back off; one Vision picked leaves it on.
  func setRotation(_ rotation: CameraRotation, automatic: Bool = false) {
    guard !recordingLocked else { return }
    guard guides.rotation != rotation || (!automatic && guides.automaticRotation),
      !automatic || guides.automaticRotation else { return }
    guides.rotation = rotation
    if !automatic { guides.automaticRotation = false }
  }

  /// Built-in, USB/Thunderbolt UVC, Continuity Camera and every virtual camera (OBS, Elgato,
  /// Blackmagic) that registers itself as an AVFoundation device — those arrive as `.external`.
  static func discovered() -> [CameraDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
      mediaType: .video, position: .unspecified
    ).devices.map {
      CameraDevice(uid: $0.uniqueID, name: $0.localizedName,
        isPhysical: $0.deviceType == .builtInWideAngleCamera || $0.deviceType == .continuityCamera
          // Only recognised physical transports may be chosen without the user's input.
          || ($0.deviceType == .external && [0x626c746e, 0x70636920, 0x75736220, 0x31333934, 0x7468756e].contains($0.transportType))) // bltn, pci, usb, 1394, thun
    }
  }

  /// Preserve saved choices. A new setup must never silently choose a virtual camera.
  static func resolve(_ savedUID: String?, in devices: [CameraDevice]) -> CameraDevice? {
    if let savedUID { return devices.first { $0.uid == savedUID } }
    return devices.first { $0.isPhysical && !$0.originalName.localizedCaseInsensitiveContains("virtual") }
  }

  func start() {
    guard observers.isEmpty else { refresh(); return }
    for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      })
    }
    Task {
      if authorization == .notDetermined {
        _ = await CaptureAccess.request(.video)
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
      }
      refresh()
    }
  }

  var unavailableMessage: String? {
    if authorization == .denied || authorization == .restricted {
      return "Allow camera access in System Settings > Privacy & Security > Camera."
    }
    if Self.resolve(selectedUID, in: devices) == nil {
      return selectedUID == nil ? (devices.isEmpty ? "Connect a camera, then choose it in the camera menu." : "Choose a camera to show its picture. Virtual cameras are never selected automatically.") : "The chosen camera is unavailable. Reconnect it or choose another camera."
    }
    return nil
  }

  /// Inventory only: validating a setup must not select a camera or open capture.
  func refreshDevices() { devices = Self.discovered().map { device in var d = device; d.nickname = nicknames[d.uid]; return d } }

  func refresh() {
    let previousMessage = unavailableMessage
    refreshDevices()
    let resolved = Self.resolve(selectedUID, in: devices)?.uid
    if selectedUID == nil, let resolved {
      selectedUID = resolved
      if let name = devices.first(where: { $0.uid == resolved })?.name {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
          userInfo: [.announcement: "Camera chosen: \(name)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
      }
    }
    if let message = unavailableMessage, message != previousMessage {
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
  }

  /// The rotation control's choices, in the Second monitor window's toolbar and the inspector alike.
  static let rotationOptions: [(String, CameraRotation?)] =
    [("Automatic", nil)] + CameraRotation.allCases.map { ($0.label, Optional($0)) }

  /// One control for the four angles and Auto: nothing chooses an angle *and* leaves Auto on.
  /// On the model, because the Second monitor window's toolbar and the inspector both show it.
  var rotationChoice: Binding<CameraRotation?> {
    Binding(
      get: { [weak self] in
        guard let self, !guides.automaticRotation else { return nil }
        return guides.rotation
      },
      set: { [weak self] value in
        guard let self else { return }
        if let value { setRotation(value) } else { guides.automaticRotation = true }
      })
  }
}

/// The camera picture in a window or behind the script. Both hand the same model to the same
/// `CameraStageView`, so the session is opened once and the guides cannot drift apart.
