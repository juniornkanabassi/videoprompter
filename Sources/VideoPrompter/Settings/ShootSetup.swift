import SwiftUI
import PrompterCore

/// Separate from reading presets: a named setup explicitly includes capture choices.
struct ShootSetup: Codable, Identifiable {
  var id = UUID()
  var name: String
  var reading: PrompterSettings
  var cameraUID: String?
  var guides: CameraGuides
  var mirrored: Bool
  var displayMode: PresenterDisplayMode
  var format: RecordingPreset
  var mirrorSavedVideo: Bool
  var separateMicrophone: Bool
  var microphoneUID: String?
  var floatAudio: Bool
}

extension AppStore {
  func saveShootSetup(named name: String, camera: CameraModel, recorder: CameraRecorder) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !recorder.settingsLocked, !session.isActivelyRunning else { return }
    shootSetups.append(ShootSetup(name: name, reading: settings, cameraUID: camera.selectedUID,
      guides: camera.guides, mirrored: camera.mirrored, displayMode: camera.displayMode,
      format: recorder.preset, mirrorSavedVideo: recorder.mirrorSavedVideo,
      separateMicrophone: recorder.usesSeparateMicrophone, microphoneUID: recorder.microphoneUID,
      floatAudio: recorder.floatAudio))
  }

  @discardableResult func applyShootSetup(_ setup: ShootSetup, camera: CameraModel, recorder: CameraRecorder) -> Bool {
    guard !recorder.settingsLocked, !session.isActivelyRunning else { return false }
    if let uid = setup.cameraUID, !camera.devices.contains(where: { $0.uid == uid }) {
      errorMessage = "The camera for \(setup.name) is unavailable. Connect it before applying this setup."
      return false
    }
    let microphones = AudioCapture.inputDevices()
    let required = [setup.reading.audioDeviceUID, setup.separateMicrophone ? setup.microphoneUID : nil].compactMap { $0 }
    guard required.allSatisfy({ uid in microphones.contains { $0.uid == uid } }) else {
      errorMessage = "A microphone for \(setup.name) is unavailable. Connect it before applying this setup."
      return false
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
        store.saveShootSetup(named: name, camera: camera, recorder: recorder); name = ""
      }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || locked)
      ForEach(store.shootSetups) { setup in
        HStack {
          Text(setup.name)
          Spacer()
          Button("Apply") { store.applyShootSetup(setup, camera: camera, recorder: recorder) }
            .accessibilityLabel("Apply \(setup.name)").disabled(locked)
        }
      }
      if locked { Text("Stop reading and recording to change a shoot setup.").font(.callout) }
    }
  }
  private var locked: Bool { recorder.settingsLocked || store.session.isActivelyRunning }
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
