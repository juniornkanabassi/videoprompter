import SwiftUI
import AppKit
import Combine
import PrompterCore

/// Separate from reading presets: a named setup explicitly includes capture choices.
struct ShootSetup: Codable, Identifiable {
  var id = UUID()
  var name: String
  var reading = PrompterSettings()
  // Legacy setups did not save the cue; applying them keeps the user's current delay.
  var startDelay: Int?
  var cameraUID: String?
  var guides = CameraGuides()
  var mirrored = false
  var displayMode = PresenterDisplayMode.prompterOnly
  var format = RecordingPreset.standard
  var mirrorSavedVideo = false
  var separateMicrophone = false
  var microphoneUID: String?
  var floatAudio = false
}

extension ShootSetup {
  static func uniqueIdentities(_ setups: [ShootSetup]) -> [ShootSetup] {
    var reserved = Set(setups.map(\.id))
    var seen = Set<UUID>()
    return setups.map { setup in
      var setup = setup
      if !seen.insert(setup.id).inserted {
        repeat { setup.id = UUID() } while reserved.contains(setup.id)
        reserved.insert(setup.id)
        seen.insert(setup.id)
      }
      return setup
    }
  }

  /// Older setups retain their known fields; missing or obsolete choices use safe defaults.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(name: try c.decode(String.self, forKey: .name))
    id = c.preference(.id, default: id)
    reading = c.preference(.reading, default: reading)
    startDelay = c.preference(.startDelay, default: startDelay)
    if let startDelay, ![0, 3, 5].contains(startDelay) { self.startDelay = nil }
    cameraUID = c.preference(.cameraUID, default: cameraUID)
    guides = c.preference(.guides, default: guides)
    mirrored = c.preference(.mirrored, default: mirrored)
    displayMode = c.preference(.displayMode, default: displayMode)
    format = c.preference(.format, default: format)
    mirrorSavedVideo = c.preference(.mirrorSavedVideo, default: mirrorSavedVideo)
    separateMicrophone = c.preference(.separateMicrophone, default: separateMicrophone)
    microphoneUID = c.preference(.microphoneUID, default: microphoneUID)
    floatAudio = c.preference(.floatAudio, default: floatAudio)
  }
}

extension AppStore {
  private func shootSetupName(_ name: String, excluding id: UUID? = nil) -> String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { shootSetupError = "Enter a name for this shoot setup."; return nil }
    guard !shootSetups.contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
      shootSetupError = "A shoot setup named \(name) already exists. Choose a different name."
      return nil
    }
    shootSetupError = nil
    return name
  }

  @discardableResult func saveShootSetup(named name: String, camera: CameraModel, recorder: CameraRecorder) -> Bool {
    guard !recorder.settingsLocked, !session.isActivelyRunning,
      let name = shootSetupName(name) else { return false }
    shootSetups.append(currentShootSetup(named: name, camera: camera, recorder: recorder))
    return true
  }

  @discardableResult func renameShootSetup(_ id: UUID, to name: String) -> Bool {
    guard let index = shootSetups.firstIndex(where: { $0.id == id }),
      let name = shootSetupName(name, excluding: id) else { return false }
    shootSetups[index].name = name
    return true
  }

  func deleteShootSetup(_ id: UUID, undoManager: UndoManager? = nil) {
    guard let index = shootSetups.firstIndex(where: { $0.id == id }) else { return }
    let setup = shootSetups.remove(at: index)
    let manager = undoManager ?? NSApp?.keyWindow?.undoManager
    manager?.registerUndo(withTarget: self) { [weak manager] target in
      target.restoreShootSetup(setup, at: index, manager: manager)
    }
    manager?.setActionName("Delete shoot setup")
    shootSetupError = nil
  }

  private func restoreShootSetup(_ setup: ShootSetup, at index: Int, manager: UndoManager?) {
    guard !shootSetups.contains(where: { $0.id == setup.id }) else { return }
    var setup = setup
    let originalName = setup.name
    var suffix = 2
    while shootSetups.contains(where: { $0.name.compare(setup.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
      setup.name = "\(originalName) (\(suffix))"
      suffix += 1
    }
    shootSetups.insert(setup, at: min(index, shootSetups.count))
    manager?.registerUndo(withTarget: self) { [weak manager] target in
      target.deleteShootSetup(setup.id, undoManager: manager)
    }
    manager?.setActionName("Delete shoot setup")
  }
  private func registerShootStateUndo(_ name: String, camera: CameraModel, recorder: CameraRecorder, manager: UndoManager?) {
    let previous = currentShootSetup(named: "Previous setup", camera: camera, recorder: recorder)
    let exposure = (camera.cleanView, camera.exposureBypassed)
    let priorRestorePoint = previousShootSetup
    let priorExposure = previousShootExposure
    let priorName = appliedShootSetupName
    registerShootUndo(name, camera: camera, recorder: recorder, manager: manager) { [weak manager] target in
      target.registerShootStateUndo(name, camera: camera, recorder: recorder, manager: manager)
      target.setShootSetup(previous, camera: camera, recorder: recorder)
      camera.cleanView = exposure.0; camera.exposureBypassed = exposure.1
      target.previousShootSetup = priorRestorePoint
      target.previousShootExposure = priorExposure
      target.appliedShootSetupName = priorName
    }
    manager?.setActionName(name)
  }
  private func registerShootUndo(_ name: String, camera: CameraModel, recorder: CameraRecorder,
                                 manager: UndoManager?, action: @escaping (AppStore) -> Void) {
    manager?.registerUndo(withTarget: self) { [weak manager] target in
      guard let manager else { return }
      guard !recorder.settingsLocked, !target.session.isActivelyRunning else {
        // Put a retry on the opposite stack now, while UndoManager owns this group.
        let id = UUID()
        let key = UndoManager.UserInfoKey(rawValue: "VideoPrompter.blockedShootUndo")
        let wasUndoing = manager.isUndoing
        manager.registerUndo(withTarget: target) { [weak manager] target in
          target.pendingShootUndos[id] = nil
          target.registerShootUndo(name, camera: camera, recorder: recorder, manager: manager, action: action)
        }
        manager.setActionName(name)
        manager.setActionUserInfoValue(id.uuidString, forKey: key)
        target.pendingShootUndos[id] = recorder.$phase.combineLatest(target.session.$state)
          .filter { phase, state in
            phase == .idle && (state == .stopped || state == .paused)
          }
          .prefix(1).sink { [weak target, weak manager] _ in
            guard let target, let manager else { return }
            target.pendingShootUndos[id] = nil
            // Only return an untouched topmost retry. Never insert above newer edits
            // or clear unrelated redo entries when capture unlocks.
            if wasUndoing {
              guard manager.canRedo,
                manager.redoActionUserInfoValue(forKey: key) as? String == id.uuidString else { return }
              manager.redo()
            } else {
              guard manager.canUndo,
                manager.undoActionUserInfoValue(forKey: key) as? String == id.uuidString else { return }
              manager.undo()
            }
          }
        return
      }
      action(target)
    }
    manager?.setActionName(name)
  }
  @discardableResult func applyShootSetup(_ setup: ShootSetup, camera: CameraModel, recorder: CameraRecorder, microphones: [AudioInputDevice] = AudioCapture.inputDevices(), undoManager: UndoManager? = nil) -> Bool {
    shootSetupError = nil
    func reject(_ message: String) -> Bool {
      shootSetupError = message
      errorMessage = message
      return false
    }
    guard !recorder.settingsLocked, !session.isActivelyRunning else {
      return reject(Features.recording ? "Stop reading and recording before applying a shoot setup." : "Stop reading before applying a shoot setup.")
    }
    camera.refreshDevices()
    if let uid = setup.cameraUID, !camera.devices.contains(where: { $0.uid == uid }) {
      return reject("The camera for \(setup.name) is unavailable. Connect it before applying this setup.")
    }
    let required = [setup.reading.audioDeviceUID, Features.recording && setup.separateMicrophone ? setup.microphoneUID : nil].compactMap { $0 }
    guard required.allSatisfy({ uid in microphones.contains { $0.uid == uid } }) else {
      return reject("A microphone for \(setup.name) is unavailable. Connect it before applying this setup.")
    }
    registerShootStateUndo("Apply shoot setup", camera: camera, recorder: recorder, manager: undoManager ?? NSApp?.keyWindow?.undoManager)
    previousShootSetup = currentShootSetup(named: "Previous setup", camera: camera, recorder: recorder)
    previousShootExposure = (camera.cleanView, camera.exposureBypassed)
    setShootSetup(setup, camera: camera, recorder: recorder)
    appliedShootSetupName = setup.name
    return true
  }

  private func currentShootSetup(named name: String, camera: CameraModel, recorder: CameraRecorder) -> ShootSetup {
    ShootSetup(name: name, reading: settings, startDelay: session.startDelay, cameraUID: camera.selectedUID,
      guides: camera.guides, mirrored: camera.mirrored, displayMode: camera.displayMode,
      format: recorder.preset, mirrorSavedVideo: recorder.mirrorSavedVideo,
      separateMicrophone: recorder.usesSeparateMicrophone, microphoneUID: recorder.microphoneUID,
      floatAudio: recorder.floatAudio)
  }

  @discardableResult func restorePreviousShootSetup(camera: CameraModel, recorder: CameraRecorder, undoManager: UndoManager? = nil) -> Bool {
    guard !recorder.settingsLocked, !session.isActivelyRunning, let previousShootSetup else { return false }
    registerShootStateUndo("Restore previous setup", camera: camera, recorder: recorder, manager: undoManager ?? NSApp?.keyWindow?.undoManager)
    // Restore the actual prior choices even if a device has since disconnected.
    setShootSetup(previousShootSetup, camera: camera, recorder: recorder)
    camera.cleanView = previousShootExposure.clean
    camera.exposureBypassed = previousShootExposure.bypassed
    self.previousShootSetup = nil
    appliedShootSetupName = nil
    shootSetupError = nil
    return true
  }

  private func setShootSetup(_ setup: ShootSetup, camera: CameraModel, recorder: CameraRecorder) {
    session.pause()
    if let startDelay = setup.startDelay { session.startDelay = startDelay }
    camera.selectedUID = setup.cameraUID
    camera.guides = setup.guides
    camera.mirrored = setup.mirrored
    camera.displayMode = setup.displayMode
    if Features.recording {
    recorder.preset = setup.format
    recorder.mirrorSavedVideo = setup.mirrorSavedVideo
    recorder.usesSeparateMicrophone = setup.separateMicrophone
    recorder.microphoneUID = setup.microphoneUID
    recorder.floatAudio = setup.floatAudio
    }
    var reading = setup.reading
    reading.id = settings.id; reading.name = settings.name
    settings = reading
    recorder.useSettings(reading)
    camera.cleanView = false; camera.exposureBypassed = false
  }
}

struct ShootSetupSection: View {
  @ObservedObject var store: AppStore
  @ObservedObject var camera: CameraModel
  @ObservedObject var recorder: CameraRecorder
  @Environment(\.undoManager) private var undoManager
  @State private var name = ""
  var body: some View {
    Section("Saved shoot setups") {
      Text(Features.recording ? "Save camera, framing, exposure, reading text, recording format and microphones together. Applying a setup keeps your script's words." : "Save camera, framing, exposure, reading text and microphone together. Applying a setup keeps your script's words.")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      if let applied = store.appliedShootSetupName {
        Text("Applied \(applied)").font(.callout)
      }
      if store.previousShootSetup != nil {
        Button("Restore previous setup") { store.restorePreviousShootSetup(camera: camera, recorder: recorder, undoManager: undoManager) }
          .disabled(locked)
      }
      TextField("Setup name", text: $name).initialPopoverFocus()
      Button("Save shoot setup") {
        if store.saveShootSetup(named: name, camera: camera, recorder: recorder) { name = "" }
      }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || locked)
      if store.shootSetups.isEmpty { Text("No saved setups yet. Save one to switch camera, framing and microphone in one step.").font(.callout) }
      ForEach(store.shootSetups) { setup in
        ShootSetupRow(store: store, camera: camera, recorder: recorder, setup: setup, locked: locked)
      }
      if let error = store.shootSetupError {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
      }
      if locked { Text(Features.recording ? "Stop reading and recording to change a shoot setup." : "Stop reading to change a shoot setup.").font(.callout) }
    }
  }
  private var locked: Bool { recorder.settingsLocked || store.session.isActivelyRunning }
}

private struct ShootSetupRow: View {
  @ObservedObject var store: AppStore
  let camera: CameraModel
  let recorder: CameraRecorder
  let setup: ShootSetup
  let locked: Bool
  @State private var renaming = false
  @Environment(\.undoManager) private var undoManager
  @State private var name = ""

  var body: some View {
    HStack {
      Text(setup.name).fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Apply") { store.applyShootSetup(setup, camera: camera, recorder: recorder, undoManager: undoManager) }
        .accessibilityLabel("Apply \(setup.name)").disabled(locked)
      Menu("Actions") {
        Button("Rename…") { name = setup.name; renaming = true }
        Button("Delete", role: .destructive) { store.deleteShootSetup(setup.id, undoManager: undoManager) }
      }.accessibilityLabel("Actions for \(setup.name)")
    }
    .alert("Rename shoot setup", isPresented: $renaming) {
      TextField("Setup name", text: $name)
      Button("Save") { store.renameShootSetup(setup.id, to: name) }
      Button("Cancel", role: .cancel) {}
    }

  }
}
