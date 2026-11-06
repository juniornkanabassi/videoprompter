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
    "Green: medium brightness. Check your face still has natural detail.",
    "Pink: brighter areas. Skin tones vary; this is not a target for every face.",
    "Yellow: nearly white. Check that bright areas still show detail.",
    "Red: the brightest areas. Lower brightness on the camera if important detail disappears."
  ]

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
    case .brightAreas: "Look for stripes where important bright areas lose detail."
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
    case .faceReference: "Stripes mark your chosen face reference."
    case .custom: "Stripes show your chosen brightness range."
    }
  }
  static let colourPurpose = "Colours show dark, medium and bright areas in the received picture."
  static let colourAction = "Adjust brightness on your camera for the detail you want to keep."
}

/// Shared settings rows keep each tool's purpose beside its switch, even when off.
struct ExposureToolToggles: View {
  @ObservedObject var model: CameraModel
  var presenter = true
  var body: some View {
    Toggle(isOn: model.exposureBinding(\.zebras, presenter: presenter)) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("Zebras").fontWeight(.semibold)
        Text(ExposureGuidance.zebraPurpose(model.guides))
      }
    }.initialPopoverFocus().accessibilityLabel("Zebras").accessibilityHint(ExposureGuidance.zebraPurpose(model.guides))
    Toggle(isOn: model.exposureBinding(\.falseColour, presenter: presenter)) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("False colour").fontWeight(.semibold)
        Text(ExposureGuidance.colourPurpose)
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
      Picker("Zebra reference", selection: Binding(
        get: { model.guides.validatedZebraPurpose },
        set: { model.guides.useZebraPreset($0) }
      )) {
        Text("Face reference").tag(CameraGuides.ZebraPurpose.faceReference)
        Text("Bright areas").tag(CameraGuides.ZebraPurpose.brightAreas)
        if model.guides.validatedZebraPurpose == .custom {
          Text("Custom levels").tag(CameraGuides.ZebraPurpose.custom)
        }
      }
      Text(ExposureGuidance.zebraAction(model.guides)).fontWeight(.semibold)
      Text(ExposureGuidance.zebraLookFor(model.guides))
      if model.exposureBypassed || (presenter && model.cleanView) {
        Button("Show exposure aids") { if presenter { model.cleanView = false }; model.exposureBypassed = false }
      }
      DisclosureGroup("Custom levels", isExpanded: $showsCustom) {
        Stepper("Level: \(model.guides.zebraLevel) IRE", value: $model.guides.zebraLevel, in: 0...100)
        Stepper("Range: ±\(model.guides.zebraRange) IRE", value: $model.guides.zebraRange, in: 0...10)
        Text("Custom levels measure brightness; they are not a face target.")
      }.accessibilityIdentifier("exposure-custom-levels")
        .accessibilityValue(showsCustom ? "Expanded" : "Collapsed")
        .accessibilityAction { showsCustom.toggle() }
      DisclosureGroup("How exposure aids work") {
        ExposureKeyHelp(model: model)
      }
      Text("Exposure aids only change the preview, not your camera or saved video.")
    }.font(.callout)
  }
}

struct ExposureLegend: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
  var respectsPresenterCleanView = true
  @State private var showsHelp = false
  static func zebraTitle(for purpose: CameraGuides.ZebraPurpose) -> String {
    switch purpose {
    case .brightAreas: "Check bright areas · Zebras"
    case .faceReference: "Check your face · Zebras"
    case .custom: "Check custom brightness · Zebras"
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
        if model.guides.falseColour { FalseColourStrip() }
        else {
          Image(systemName: "circle.lefthalf.striped.horizontal")
            .accessibilityLabel("Zebras on")
        }
        Button { showsHelp.toggle() } label: {
          HStack(spacing: Space.xs) {
            Text("Key")
            Image(systemName: "chevron.down").imageScale(.small)
          }.fixedSize()
        }
        .accessibilityLabel("Key")
        .accessibilityHint("Shows camera actions, colour meanings and brightness levels")
        .restoringPopoverFocus(isPresented: $showsHelp, identifier: "exposure-key")
        .popover(isPresented: $showsHelp) {
          ExposureKeyPanel(model: model, zoom: zoom).popoverEntryFocus()
        }
      }.font(.callout).foregroundStyle(.primary)
        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
        .background(Color(white: 0.12), in: .rect(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .uiZoom(zoom)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("exposure-key-strip")
    }
  }


}

/// The strip has no text that can wrap. Names, calibration and actions belong in Key.
struct FalseColourStrip: View {
  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(CameraExposure.bands.enumerated()), id: \.offset) { index, band in
        Rectangle().fill(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
          .frame(minWidth: Space.xs, maxWidth: .infinity)
          .accessibilityLabel("\(FalseColourKey.labels[index]). \(band.name)")
      }
    }.frame(maxWidth: 240).frame(height: Space.sm)
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
      .background(Color(white: 0.12))
      .environment(\.colorScheme, .dark)
      .uiZoom(zoom)
  }
}

/// Action first; measurements and the received-picture qualification follow it.
struct ExposureKeyHelp: View {
  @ObservedObject var model: CameraModel
  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text(model.guides.zebras ? ExposureGuidance.zebraAction(model.guides) : ExposureGuidance.colourAction)
        .fontWeight(.semibold).initialPopoverFocus()
      if model.guides.zebras { Text(ExposureGuidance.zebraLookFor(model.guides)) }
      if model.guides.falseColour { Text(ExposureGuidance.colourLookFor) }
      if model.guides.zebras {
        Text(ExposureLegend.zebraTitle(for: model.guides.validatedZebraPurpose)).fontWeight(.semibold)
        Text(ExposureLegend.measurement(level: model.guides.zebraLevel, range: model.guides.zebraRange))
      }
      if model.guides.falseColour {
        FalseColourKey()
        ForEach(ExposureGuidance.colourMeanings, id: \.self) { Text($0) }
      }
      Text("Skin tones vary; green and pink are not targets for every face. For flat picture settings, follow your camera's guidance.")
      Text("These guides show the received picture. They do not change your camera or saved video.")
    }.font(.callout).foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

  }
}

/// Use the renderer's ranges, so the detailed key cannot drift from its colours.
struct FalseColourKey: View {
  static let labels = ["Black", "Dark", "Mid", "Bright", "High", "White"]
  static func rangeLabel(_ range: ClosedRange<Double>) -> String {
    "\(range.lowerBound.formatted(.number.precision(.fractionLength(0...1))))–\(range.upperBound.formatted(.number.precision(.fractionLength(0...1))))%"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("Check brightness · False colour").fontWeight(.semibold)
      ForEach(Array(CameraExposure.bands.enumerated()), id: \.offset) { index, band in
        HStack(spacing: Space.sm) {
          Rectangle().fill(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
            .frame(width: Space.md, height: Space.md)
          Text(Self.labels[index])
          Spacer(minLength: Space.xs)
          Text(Self.rangeLabel(band.range)).monospacedDigit()
            .foregroundStyle(Color.primary.opacity(0.75))
        }.accessibilityElement(children: .ignore)
          .accessibilityLabel("\(Self.labels[index]). \(band.name)")
          .accessibilityValue(Self.rangeLabel(band.range))
      }
      Text("Grey shows brightness between these bands.")
    }.font(.callout).fixedSize(horizontal: false, vertical: true)
  }
}
