import SwiftUI

/// Meaning stays beside the monitor, numeric calibration stays in detailed help.
struct ExposureGuidance: View {
  let zebras: Bool
  let guides: CameraGuides
  let falseColour: Bool

  init(zebras: Bool, guides: CameraGuides, falseColour: Bool) {
    self.zebras = zebras; self.guides = guides; self.falseColour = falseColour
  }
  // Compatibility for existing face-preset snapshots; arbitrary bands must pass their guides.
  init(zebras: Bool, face: Bool, falseColour: Bool) {
    var guides = CameraGuides()
    if face { guides.useZebraPreset(.faceReference) }
    self.init(zebras: zebras, guides: guides, falseColour: falseColour)
  }

  static let colourMeanings = [
    "Purple: almost black. Detail may be lost in shadows.",
    "Blue: very dark. Brighten important shadow areas if you need to see detail.",
    "Green: medium brightness. Check important areas still have detail.",
    "Pink: my skin reference. Check important areas still have detail.",
    "Yellow: nearly white. Check that bright areas still show detail.",
    "Red: the received picture is at or near white. Check for lost detail on your camera."
  ]
  static let cameraJudgement = "Your camera’s own monitor is the final judge of exposure."

  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      if zebras {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text(Self.zebraAction(guides)).fontWeight(.semibold)
          Text(Self.zebraLookFor(guides))
        }
      }
      if falseColour { Text(Self.colourLookFor) }
    }.font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
  }

  static func zebraLookFor(_ guides: CameraGuides) -> String {
    switch guides.validatedZebraPurpose {
    case .brightAreas: "Stripes flag bright areas to check; they do not prove that detail is lost. Check important highlights on your camera."
    case .faceReference: "Look for natural detail on the lit cheek. Skin tones vary; there is no single target for every face. For a flat picture setting, follow your camera's guidance."
    case .custom: "Look for stripes within your chosen brightness range. This is a measurement, not a face target."
    }
  }

  static func zebraAction(_ guides: CameraGuides) -> String {
    if let warning = guides.zebraWarning { return warning }
    return guides.validatedZebraPurpose == .brightAreas
      ? "Lower exposure on your camera if important detail disappears."
      : "Adjust exposure on your camera for the detail you want to keep."
  }
  static let colourLookFor = "Look for detail in the dark and bright areas."

  static func zebraPurpose(_ guides: CameraGuides) -> String {
    switch guides.validatedZebraPurpose {
    case .brightAreas: "Stripes show the brightest areas."
    case .faceReference: "Stripes mark the selected brightness reference."
    case .custom: "Stripes show your chosen brightness range."
    }
  }
  static let colourPurpose = "Colours show dark, medium and bright areas in the received picture."
  static let facePurpose = "A reference for the lit cheek in standard video, not a target for every face. Skin tones vary; for flat picture settings, follow your camera's guidance."
  static let colourAction = "Adjust brightness on your camera for the detail you want to keep."
}

/// Shared settings rows keep each tool's purpose beside its switch, even when off.
struct ExposureToolToggles: View {
  @ObservedObject var model: CameraModel
  var presenter = true
  private func binding(_ key: WritableKeyPath<CameraGuides, Bool>) -> Binding<Bool> {
    model.exposureBinding(key, presenter: presenter)
  }

  var body: some View {
    Toggle(isOn: binding(\.zebras)) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(ExposureLegend.zebraTitle(for: model.guides.validatedZebraPurpose)).fontWeight(.semibold)
        Text(ExposureGuidance.zebraPurpose(model.guides)).font(.callout)
      }
    }.initialPopoverFocus().accessibilityLabel(ExposureLegend.zebraTitle(for: model.guides.validatedZebraPurpose)).accessibilityHint(ExposureGuidance.zebraPurpose(model.guides))
    Toggle(isOn: binding(\.falseColour)) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("False colour").fontWeight(.semibold)
        Text(ExposureGuidance.colourPurpose).font(.callout)
      }
    }.accessibilityLabel("False colour").accessibilityHint(ExposureGuidance.colourPurpose)
  }
}

/// Full exposure contents, shared by the settings page and the presenter's Exposure job.
/// Intended for CameraExposureSections so both hosts keep exactly the same controls.
struct ExposureSettingsContent: View {
  @ObservedObject var model: CameraModel
  var presenter = true
  @State private var showsCustom = false
  var body: some View {
    Section("Exposure") {
      ExposureToolToggles(model: model, presenter: presenter)
      Text(ExposureGuidance.zebraAction(model.guides)).fontWeight(.semibold)
      Text(ExposureGuidance.zebraLookFor(model.guides))
      if model.exposureBypassed || (presenter && model.cleanView) {
        Button("Show exposure aids") { if presenter { model.cleanView = false }; model.exposureBypassed = false }
      }
      DisclosureGroup("Custom levels", isExpanded: $showsCustom) {
        ZebraSettings(guides: model.exposureControls, model: model)
        Text("Custom levels measure brightness; they are not a face target.")
      }.accessibilityIdentifier("exposure-custom-levels")
        .accessibilityValue(showsCustom ? "Expanded" : "Collapsed")
        .accessibilityAction { showsCustom.toggle() }
      DisclosureGroup("How exposure aids work") {
        ExposureKeyHelp(model: model)
      }
      Text("Exposure aids only change the preview, not your camera.")
    }.font(.callout)
  }
}

struct ExposureLegend: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
  var respectsPresenterCleanView = true
  @State private var showsHelp = false
  @State private var adjusting: AdjustTab?
  static func zebraTitle(for purpose: CameraGuides.ZebraPurpose) -> String {
    switch purpose {
    case .brightAreas: "Zebras · Highlights"
    case .faceReference: "Zebras · My skin"
    case .custom: "Zebras · Custom"
    }
  }
  static func measurement(level: Int, range: Int) -> String {
    range > 0
      ? "Stripes mark \(max(0, level - range))–\(min(100, level + range)) on a 0–100 brightness scale in the received picture."
      : "Stripes mark \(level) and above on a 0–100 brightness scale in the received picture."
  }

  var body: some View {
    if model.exposureIsConfigured && (!respectsPresenterCleanView || !model.cleanView) && !model.exposureBypassed {
      HStack(spacing: Space.sm) {
        if model.guides.falseColour {
          ViewThatFits(in: .horizontal) {
            FalseColourStrip()
            FalseColourStrip(showsLabels: false)
          }
        }
        else {
          Image(systemName: "circle.lefthalf.striped.horizontal")
            .accessibilityLabel("Zebras on")
        }
        Button { showsHelp.toggle() } label: {
          HStack(spacing: Space.xs) {
            Text("Key")
            Image(systemName: "chevron.down").imageScale(.small)
          }.fixedSize().frame(minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Key")
        .accessibilityHint("Shows camera actions, colour meanings and brightness levels")
        .restoringPopoverFocus(isPresented: $showsHelp, identifier: "exposure-key")
        .popover(isPresented: $showsHelp) {
          ExposureKeyPanel(model: model, zoom: zoom).popoverEntryFocus()
        }
      }.font(.callout).foregroundStyle(.primary)
        .contextMenu {
          let state = ExposureMenuLogic.state(from: model.guides)
          Button("Show key") { showsHelp = true }
          Menu("Zebras (\(ExposureMenuLogic.zebraSummary(state)))") { ZebraMenuContent(model: model) { adjusting = .zebras } }
          Menu("False colour (\(ExposureMenuLogic.colourSummary(state)))") { FalseColourMenuContent(model: model) { adjusting = .falseColour } }
        }
        .popover(isPresented: Binding(get: { adjusting != nil }, set: { if !$0 { adjusting = nil } })) {
          ScrollView {
            if adjusting == .falseColour { FalseColourAdjustView(model: model) } else { ZebraAdjustView(model: model) }
          }.padding(Space.lg).frame(width: 460, height: 560)
            .background(Surfaces.presenterPanel).environment(\.colorScheme, .dark).uiZoom(zoom)
        }
        .padding(.horizontal, Space.sm)
        .background(Surfaces.presenterPanel, in: .rect(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .uiZoom(zoom)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("exposure-key-strip")
    }
  }


}

/// Discrete measured bands, with quiet ticks and captions away from the colour.
struct FalseColourStrip: View {
  @Environment(\.colorSchemeContrast) private var contrast
  static let captions = ["Near black", "Mid grey", "Near white", "Signal white"]
  static let bandGroups = [0..<2, 2..<4, 4..<5, 5..<6]
  var showsLabels = true
  var body: some View {
    HStack(spacing: showsLabels ? Space.sm : Space.xs) {
      ForEach(Self.captions.indices, id: \.self) { index in
        VStack(spacing: 0) {
          HStack(spacing: Space.xs) {
            ForEach(Self.bandGroups[index], id: \.self) { bandIndex in
              let band = CameraExposure.bands[bandIndex]
              Rectangle().fill(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
                .frame(minWidth: Space.xs, maxWidth: .infinity)
                .frame(height: Space.xs)
                .accessibilityLabel("\(CameraExposure.bands[bandIndex].name). \(band.name)")
            }
          }
          Rectangle().fill(Palette.onDarkQuiet(contrast)).frame(width: 1, height: Space.xs)
            .accessibilityHidden(true)
          if showsLabels {
            Text(Self.captions[index]).font(.callout).foregroundStyle(.white)
              .lineLimit(1).fixedSize()
          }
        }.frame(maxWidth: .infinity)
          .accessibilityHint(index == 3
            ? "At or near white in the received picture, not proof of camera sensor clipping. Open Key for brightness levels."
            : "Open Key for received-picture brightness levels.")
      }
    }.frame(maxWidth: 480).fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("False colour strip")
  }
}

/// Keep explanatory text on the same opaque dark surface as the monitor key.
struct ExposureKeyPanel: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
  var body: some View {
    ScrollView { ExposureKeyHelp(model: model).padding(Space.md) }
      .frame(width: 320, height: 300)
      .background(Surfaces.presenterPanel)
      .environment(\.colorScheme, .dark)
      .uiZoom(zoom)
  }
}

/// Action first; measurements and the received-picture qualification follow it.
struct ExposureKeyHelp: View {
  @ObservedObject var model: CameraModel
  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text(ExposureGuidance.cameraJudgement)
      Text(model.guides.zebras ? ExposureGuidance.zebraAction(model.guides) : ExposureGuidance.colourAction)
        .fontWeight(.semibold).initialPopoverFocus()
      if model.guides.zebras { Text(ExposureGuidance.zebraLookFor(model.guides)) }
      if model.guides.falseColour { Text(ExposureGuidance.colourLookFor) }
      if model.guides.zebras {
        Text(ExposureLegend.zebraTitle(for: model.guides.validatedZebraPurpose)).fontWeight(.semibold)
        Text(ExposureLegend.measurement(level: model.guides.zebraLevel, range: model.guides.zebraRange))
      }
      if model.guides.falseColour {
        FalseColourKey(settings: model.guides.exposure)
      }
      Text("These guides show the received picture. They do not change your camera.")
    }.font(.callout).foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

  }
}


/// Shared by the HUD popover and Tools; zero width is the persisted Limit mode.
struct ZebraSettings: View {
  @Binding var guides: CameraGuides
  var model: CameraModel? = nil
  var onPreset: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Picker("Zebra mode", selection: (model?.zebraBinding(\.zebraRangeMode) ?? $guides.manualExposure(\.zebraRangeMode))) {
        Text("Limit").tag(false)
        Text("Range").tag(true)
      }.pickerStyle(.segmented)
      Stepper(value: (model?.zebraBinding(\.zebraLevel) ?? $guides.manualExposure(\.zebraLevel)), in: 0...100) {
        HStack {
          Text("Level")
          Spacer(minLength: Space.sm)
          Text("\(guides.zebraLevel) IRE").font(.title2.weight(.semibold)).monospacedDigit()
        }
      }
      if guides.zebraRangeMode {
        Stepper("Plus or minus: \(guides.zebraRange) IRE", value: (model?.zebraBinding(\.zebraRange) ?? $guides.manualExposure(\.zebraRange)), in: 1...10)
      }
      HStack(spacing: Space.sm) {
        Button("My skin") {
          if let model { model.chooseZebraPreset(.faceReference) } else { guides.changeExposure { $0.useZebraPreset(.faceReference) } }
          onPreset()
        }
        Button("Highlights") { if let model { model.chooseZebraPreset(.brightAreas) } else { guides.changeExposure { $0.useZebraPreset(.brightAreas) } }; onPreset() }
      }
      Text((model?.effectiveGuides ?? guides).exposure.zebraReadout).font(.callout)
    }
  }
}

/// The setup card and the smaller indicator used while reading.
struct ExposureKey: View {
  let guides: CameraGuides
  var compact = false
  var zoom = 1.0
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if compact {
        if guides.zebras { Text("Zebras on") }
        if guides.falseColour { Text("False colour on") }
      } else {
        Text("EXPOSURE KEY").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        if guides.zebras {
          HStack(spacing: 16) {
            PresenterZebraSwatch().frame(width: 44, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading) {
              Text("Zebras").font(.system(size: 19, weight: .semibold))
              Text((guides.validatedZebraPurpose == .faceReference ? "Skin, " : "") + guides.exposure.zebraRangeLabel + " IRE").font(.system(size: 15)).foregroundStyle(.secondary)
            }
          }
        }
        if guides.falseColour {
          ForEach(Array(guides.exposure.legendBands.enumerated()), id: \.offset) { _, band in
            HStack(spacing: 16) {
              RoundedRectangle(cornerRadius: 4).fill(Color(red: Double(band.colour & 255)/255, green: Double((band.colour >> 8) & 255)/255, blue: Double((band.colour >> 16) & 255)/255)).frame(width: 44, height: 28)
              VStack(alignment: .leading) {
                Text(band.label).font(.system(size: 19, weight: .semibold))
                Text(band.range + " IRE").font(.system(size: 15)).foregroundStyle(.secondary)
              }
            }
          }
        }
        Text("Everything else shows in grey. Measured from the incoming picture.").font(.system(size: 13)).foregroundStyle(.secondary)
      }
    }.padding(16).foregroundStyle(.white).background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
      .environment(\.colorScheme, .dark).uiZoom(zoom)
  }
}
