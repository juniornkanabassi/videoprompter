import SwiftUI
import PrompterCore

/// Separate from reading presets: a named setup explicitly includes capture choices.
struct ShootSetup: Codable, Identifiable {
  var id = UUID()
  var name: String
  var reading = PrompterSettings()
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
  /// Older setups retain their known fields; missing or obsolete choices use safe defaults.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(name: try c.decode(String.self, forKey: .name))
    id = c.preference(.id, default: id)
    reading = c.preference(.reading, default: reading)
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
    shootSetups.append(ShootSetup(name: name, reading: settings, cameraUID: camera.selectedUID,
      guides: camera.guides, mirrored: camera.mirrored, displayMode: camera.displayMode,
      format: recorder.preset, mirrorSavedVideo: recorder.mirrorSavedVideo,
      separateMicrophone: recorder.usesSeparateMicrophone, microphoneUID: recorder.microphoneUID,
      floatAudio: recorder.floatAudio))
    return true
  }

  @discardableResult func renameShootSetup(_ id: UUID, to name: String) -> Bool {
    guard let index = shootSetups.firstIndex(where: { $0.id == id }),
      let name = shootSetupName(name, excluding: id) else { return false }
    shootSetups[index].name = name
    return true
  }

  func deleteShootSetup(_ id: UUID) {
    shootSetups.removeAll { $0.id == id }
    shootSetupError = nil
  }

  @discardableResult func applyShootSetup(_ setup: ShootSetup, camera: CameraModel, recorder: CameraRecorder, microphones: [AudioInputDevice] = AudioCapture.inputDevices()) -> Bool {
    shootSetupError = nil
    func reject(_ message: String) -> Bool {
      shootSetupError = message
      errorMessage = message
      return false
    }
    guard !recorder.settingsLocked, !session.isActivelyRunning else {
      return reject("Stop reading and recording before applying a shoot setup.")
    }
    camera.refreshDevices()
    if let uid = setup.cameraUID, !camera.devices.contains(where: { $0.uid == uid }) {
      return reject("The camera for \(setup.name) is unavailable. Connect it before applying this setup.")
    }
    let required = [setup.reading.audioDeviceUID, setup.separateMicrophone ? setup.microphoneUID : nil].compactMap { $0 }
    guard required.allSatisfy({ uid in microphones.contains { $0.uid == uid } }) else {
      return reject("A microphone for \(setup.name) is unavailable. Connect it before applying this setup.")
    }
    session.pause()
    camera.selectedUID = setup.cameraUID
    camera.guides = setup.guides
    camera.mirrored = setup.mirrored
    camera.displayMode = setup.displayMode
    recorder.preset = setup.format
    recorder.mirrorSavedVideo = setup.mirrorSavedVideo
    recorder.usesSeparateMicrophone = setup.separateMicrophone
    recorder.microphoneUID = setup.microphoneUID
    recorder.floatAudio = setup.floatAudio
    var reading = setup.reading
    reading.id = settings.id; reading.name = settings.name
    settings = reading
    recorder.useSettings(reading)
    camera.cleanView = false; camera.exposureBypassed = false
    return true
  }
}

struct ShootSetupSection: View {
  @ObservedObject var store: AppStore
  @ObservedObject var camera: CameraModel
  @ObservedObject var recorder: CameraRecorder
  @State private var name = ""
  var body: some View {
    Section("Saved shoot setups") {
      Text("Save camera, framing, exposure, reading text, recording format and microphones together. Applying a setup keeps your script's words.")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      TextField("Setup name", text: $name).initialPopoverFocus()
      Button("Save shoot setup") {
        if store.saveShootSetup(named: name, camera: camera, recorder: recorder) { name = "" }
      }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || locked)
      ForEach(store.shootSetups) { setup in
        ShootSetupRow(store: store, camera: camera, recorder: recorder, setup: setup, locked: locked)
      }
      if let error = store.shootSetupError {
        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      if locked { Text("Stop reading and recording to change a shoot setup.").font(.callout) }
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
  @State private var deleting = false
  @State private var name = ""

  var body: some View {
    HStack {
      Text(setup.name).fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Apply") { store.applyShootSetup(setup, camera: camera, recorder: recorder) }
        .accessibilityLabel("Apply \(setup.name)").disabled(locked)
      Menu("Actions") {
        Button("Rename…") { name = setup.name; renaming = true }
        Button("Delete…", role: .destructive) { deleting = true }
      }.accessibilityLabel("Actions for \(setup.name)")
    }
    .alert("Rename shoot setup", isPresented: $renaming) {
      TextField("Setup name", text: $name)
      Button("Save") { store.renameShootSetup(setup.id, to: name) }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Delete \(setup.name)?", isPresented: $deleting) {
      Button("Delete", role: .destructive) { store.deleteShootSetup(setup.id) }
      Button("Cancel", role: .cancel) {}
    } message: { Text("This removes the saved setup. Your current camera and reading settings stay unchanged.") }
  }
}

struct PresenterHelp: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.md) {
        Text("Presenter help").font(.title2)
        Text("Start reading moves the script. Record saves the camera and microphone. Each starts and stops separately.")
        Text("Back to start returns to the first word without stopping a recording.")
        Text("Tools contains Text, Camera, Exposure and Microphone. Camera view shows the picture without a script. Script and camera puts your words over it.")
        Text("Clean presenter view hides the script and guides here. The second Camera Monitor keeps its overlays.")
        Text("Mirror for teleprompter glass changes your reading text. Camera preview mirroring and saved-video mirroring are separate choices in Camera settings.")
        Button("Done") { dismiss() }.initialPopoverFocus()
      }.font(.callout).padding(Space.md)
    }.frame(width: 400, height: 400)
  }
  @Environment(\.dismiss) private var dismiss
}
