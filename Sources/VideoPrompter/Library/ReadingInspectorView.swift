import AppKit
import SwiftUI
import PrompterCore

/// Shared by Settings and the presenter's Reading segment.
struct ReadingSettingsPage: View {
  @ObservedObject var store: AppStore
  @ObservedObject var camera: CameraModel
  @Environment(\.undoManager) private var undoManager
  @State private var previousAppearance: PrompterSettings?

  init(store: AppStore, camera: CameraModel = .shared) {
    self.store = store
    self.camera = camera
  }

  var body: some View {
    Form {
      Section("Following") {
        Text("Reading settings apply to all scripts. Save a reading preset to reuse a look.")
          .font(.callout).foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if store.settings.mode == "Manual" { AutomaticScrollDelay(session: store.session) }
        ReadingChoice(title: "Mode", values: ["Voice", "Manual"], names: ["Voice follow", "Automatic scroll"], selection: $store.settings.mode, zoom: store.uiZoom)
        if store.settings.mode == "Manual" {
          slider("Reading speed", value: $store.settings.speed, range: 20...300, readout: "\(Int(store.settings.speed)) words/min", spoken: "\(Int(store.settings.speed)) words per minute")
        }
      }
      Section("Reading text") {
        ReadingChoice(title: "Reading font", values: AvailableFonts.presenter, names: AvailableFonts.presenter, selection: $store.settings.fontName, zoom: store.uiZoom)
        slider("Reading text size", value: $store.settings.fontSize, range: AppStore.presenterFontSizes, readout: "\(Int(store.settings.fontSize)) pt", spoken: "\(Int(store.settings.fontSize)) points")
        ReadingChoice(title: "Text weight", values: ["Regular", "Bold"], names: ["Regular", "Bold"], selection: $store.settings.fontWeight, zoom: store.uiZoom)
        Toggle("Mirror for teleprompter glass", isOn: $store.settings.horizontalMirror)
        Button("Show in Presenter") { PresenterController.shared.presentFromLibrary(store: store) }
          .help("See your reading appearance settings in the presenter")
          .disabled(store.selected == nil)
      }
      Section("Layout") {
        percent("Text width", $store.settings.textWidth, PrompterSettings.textWidthRange)
        Button("Narrow Column") { store.settings.textWidth = 0.65 }
        ReadingChoice(title: "Alignment", values: ["Left", "Center", "Right"], names: ["Left", "Centre", "Right"], selection: $store.settings.alignment, zoom: store.uiZoom)
        percent("Line spacing", $store.settings.lineSpacing, 0...0.5)
        percent("Paragraph spacing", $store.settings.paragraphSpacing, 0...1)
        ReadingLayoutPreview(settings: store.settings, overVideo: camera.presentsWithVideo)
      }
      Section("Reading guide") {
        percent("Guide position", $store.settings.guideFraction, 0.1...0.85)
        percent("Guide visibility", $store.settings.guideOpacity, 0...1)
        Toggle("Highlight active word", isOn: $store.settings.highlightActiveWord)
      }
      Section("Colours") {
        percent("Text visibility", $store.settings.textOpacity, 0.2...1)
        percent(camera.presentsWithVideo ? "Background over camera" : "Script-only background", backdropOpacity, PrompterSettings.backdropOpacityRange(withVideo: camera.presentsWithVideo))
        ColorPicker("Text colour", selection: colour($store.settings.textColorHex), supportsOpacity: false)
        ColorPicker("Background colour", selection: colour($store.settings.backgroundColorHex), supportsOpacity: false)
        let recovery = ReadingRecovery(current: store.settings, overVideo: camera.presentsWithVideo)
        ReadingContrastWarning(textHex: store.settings.textColorHex, textOpacity: store.settings.textOpacity,
          backgroundHex: store.settings.backgroundColorHex, darkness: backdropOpacity,
          minimumOpacityScale: store.settings.showCues ? 0.42 : 0.5,
          threshold: store.settings.fontSize >= 24 ? 3 : 4.5,
          highlightHex: store.settings.highlightActiveWord ? NSColor.systemYellow.hex : nil,
          makeReadable: {
            previousAppearance = store.settings
            store.applyPreset(recovery.settings, undoManager: undoManager)
            undoManager?.setActionName("Make Readable")
            LibraryAnnouncement.post("Readable colours applied. Undo Make Readable is available.")
          }, overVideo: camera.presentsWithVideo, changeExplanation: recovery.explanation)
        if let previousAppearance {
          Button("Undo Make Readable") {
            store.applyPreset(previousAppearance, undoManager: undoManager)
            self.previousAppearance = nil
          }
        }
      }
      Section("Rotation and stage directions") {
        Toggle("Mirror text top to bottom", isOn: $store.settings.verticalMirror)
        ReadingChoice(title: "Text rotation", values: [0, 180], names: ["0°", "180°"], selection: $store.settings.rotation, zoom: store.uiZoom)
        Toggle("Show stage directions", isOn: $store.settings.showCues)
      }
    }.formStyle(.grouped)
      .onChange(of: store.settings.fontSize) { _, value in
        LibraryAnnouncement.post("Reading text \(Int(value)) points")
      }
  }

  private func percent(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    slider(title, value: value, range: range, readout: "\(Int(value.wrappedValue * 100))%", spoken: "\(Int(value.wrappedValue * 100)) percent")
  }
  private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String, spoken: String) -> some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Text(readout).monospacedDigit().font(UIType.secondary)
      }
      ReadingSlider(value: value, range: range, title: title, spokenValue: spoken)
    }
  }
  private func colour(_ value: Binding<String>) -> Binding<Color> {
    Binding(get: { Color(nsColor: NSColor(hex: value.wrappedValue) ?? .black) }, set: { value.wrappedValue = NSColor($0).hex })
  }
  private var backdropOpacity: Binding<Double> {
    Binding(get: { store.settings.backdropOpacity(withVideo: camera.presentsWithVideo) },
      set: { store.settings.setBackdropOpacity($0, withVideo: camera.presentsWithVideo) })
  }
}

typealias ReadingInspectorView = ReadingSettingsPage

/// A Picker retains the selected menu item's native state at every interface size.
struct ReadingChoice<Value: Hashable>: View {
  let title: String
  let values: [Value]
  let names: [String]
  @Binding var selection: Value
  let zoom: Double

  var selectedName: String {
    values.firstIndex(of: selection).map { names[$0] } ?? String(describing: selection)
  }
  var body: some View {
    let layout = zoom >= 1.5 ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs)) : AnyLayout(HStackLayout(spacing: Space.sm))
    layout {
      Text(title).fixedSize(horizontal: false, vertical: true)
      if zoom < 1.5 { Spacer() }
      if zoom >= 1.5 {
        Menu {
          Picker(title, selection: $selection) {
            ForEach(values.indices, id: \.self) { index in
              ReadingChoiceOption(name: names[index], isSelected: selection == values[index]).tag(values[index])
            }
          }.pickerStyle(.inline)
        } label: {
          Text(selectedName).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.menuIndicator(.visible).accessibilityLabel(title).accessibilityValue(selectedName)
      } else {
        InspectorChoice(title: title, values: values, names: names, selection: $selection)
      }
    }
  }
}

struct ReadingChoiceOption: View {
  let name: String
  let isSelected: Bool
  var body: some View {
    Text(name).accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
