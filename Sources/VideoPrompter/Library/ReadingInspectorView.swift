import AppKit
import SwiftUI

/// The same reading setup can be opened beside a script or from the presenter.
struct ReadingInspectorView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var camera: CameraModel
  var onVoiceSettings: (() -> Void)?
  init(store: AppStore, camera: CameraModel = .shared, onVoiceSettings: (() -> Void)? = nil) {
    self.store = store; self.camera = camera; self.onVoiceSettings = onVoiceSettings
  }
  @State private var typography = false
  @State private var guide = false
  @State private var backdrop = false
  @State private var advanced = false
  @State private var cameraSettings = false
  @Environment(\.openSettings) private var openSettings
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.xxl) {
        InspectorSection("Reading settings") {
          Text("These settings change the presenter. Editor text size is beside your script.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
          choice("Presenter view", values: [.prompterOnly, .prompterWithVideo, .videoOnly],
            names: ["Script", "Script and camera", "Camera Only"], selection: $camera.displayMode)
          if camera.presentsWithVideo {
            Button("Camera Settings…") { cameraSettings = true }.buttonStyle(.link)
              .popover(isPresented: $cameraSettings) {
                CameraSettingsPanel(model: camera, zoom: store.uiZoom).frame(width: 320).uiZoom(store.uiZoom)
              }
          }
        }
        InspectorSection("Reading mode") {
          choice("Reading mode", values: ["Voice", "Manual"], names: ["Voice follow", "Automatic scroll"], selection: $store.settings.mode)
          if store.settings.mode == "Manual" {
            slider("Reading speed", value: $store.settings.speed, range: 20...300,
              readout: "\(Int(store.settings.speed)) words/min", spoken: "\(Int(store.settings.speed)) words per minute")
          } else {
            Button("Voice and Microphone Settings…") {
              if let onVoiceSettings { onVoiceSettings() } else { AppSettingsView.requestVoiceTab(); openSettings() }
            }.buttonStyle(.link)
          }
        }
        InspectorSection("Reading text") {
          choice("Reading font", values: AvailableFonts.presenter, names: AvailableFonts.presenter, selection: $store.settings.fontName)
          slider("Reading text size", value: $store.settings.fontSize, range: AppStore.presenterFontSizes,
            readout: "\(Int(store.settings.fontSize)) pt", spoken: "\(Int(store.settings.fontSize)) points")
          Toggle("Mirror for teleprompter glass", isOn: $store.settings.horizontalMirror)
          DisclosureGroup("Spacing and alignment", isExpanded: $typography) {
            VStack(alignment: .leading, spacing: Space.md) {
              choice("Text weight", values: ["Regular", "Bold"], names: ["Regular", "Bold"], selection: $store.settings.fontWeight)
              choice("Alignment", values: ["Left", "Center", "Right"], names: ["Left", "Centre", "Right"], selection: $store.settings.alignment)
              percent("Text width", $store.settings.textWidth, PrompterSettings.textWidthRange)
              percent("Line spacing", $store.settings.lineSpacing, 0...0.5)
              percent("Paragraph spacing", $store.settings.paragraphSpacing, 0...1)
            }.padding(.top, Space.md)
          }
        }
        DisclosureGroup("Reading guide", isExpanded: $guide) {
          VStack(spacing: Space.md) {
            percent("Guide position", $store.settings.guideFraction, 0.1...0.85)
            percent("Guide visibility", $store.settings.guideOpacity, 0...1)
            Toggle("Highlight active word", isOn: $store.settings.highlightActiveWord)
          }.padding(.top, Space.md)
        }
        DisclosureGroup("Colours and backdrop", isExpanded: $backdrop) {
          VStack(spacing: Space.md) {
            percent("Text visibility", $store.settings.textOpacity, 0.2...1)
            percent("Background darkness", backdropOpacity, PrompterSettings.backdropOpacityRange(withVideo: camera.presentsWithVideo))
            ColorPicker("Text colour", selection: colour($store.settings.textColorHex), supportsOpacity: false)
            ColorPicker("Background colour", selection: colour($store.settings.backgroundColorHex), supportsOpacity: false)
          }.padding(.top, Space.md)
        }
        DisclosureGroup("Rotation and stage directions", isExpanded: $advanced) {
          VStack(alignment: .leading, spacing: Space.md) {
            Toggle("Mirror text top to bottom", isOn: $store.settings.verticalMirror)
            choice("Text rotation", values: [0, 180], names: ["0°", "180°"], selection: $store.settings.rotation)
            Toggle("Show stage directions", isOn: $store.settings.showCues)
          }.padding(.top, Space.md)
        }
      }.padding(Space.lg)
    }.foregroundStyle(LibraryAppearance.color(.labelColor, scheme: scheme))
      .background(LibraryAppearance.color(.windowBackgroundColor, scheme: scheme))
  }

  private func choice<Value: Hashable>(_ title: String, values: [Value], names: [String], selection: Binding<Value>) -> some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text(title)
      // A wrapping current value remains readable even when a native popup is too narrow.
      if store.uiZoom >= 1.5 {
        Text(values.firstIndex(of: selection.wrappedValue).map { names[$0] } ?? "")
          .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
      }
      InspectorChoice(title: title, values: values, names: names, selection: selection)
    }
  }
  private func percent(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    slider(title, value: value, range: range, readout: "\(Int(value.wrappedValue * 100))%", spoken: "\(Int(value.wrappedValue * 100)) percent")
  }
  private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String, spoken: String) -> some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text(title).fixedSize(horizontal: false, vertical: true)
      Text(readout).monospacedDigit().font(.callout)
      Slider(value: value, in: range).accessibilityLabel(title).accessibilityValue(spoken)
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
