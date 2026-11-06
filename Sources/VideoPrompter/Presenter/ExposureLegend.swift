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
  var body: some View {
    Toggle(isOn: model.exposureBinding(\.zebras)) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("Zebras").fontWeight(.semibold)
        Text(ExposureGuidance.zebraPurpose(model.guides))
      }
    }.accessibilityLabel("Zebras").accessibilityHint(ExposureGuidance.zebraPurpose(model.guides))
    Toggle(isOn: model.exposureBinding(\.falseColour)) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("False colour").fontWeight(.semibold)
        Text(ExposureGuidance.colourPurpose)
      }
    }.accessibilityLabel("False colour").accessibilityHint(ExposureGuidance.colourPurpose)
  }
}

struct ExposureLegend: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
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
    if model.exposureIsConfigured && !model.cleanView && !model.exposureBypassed {
      VStack(alignment: .leading, spacing: Space.xs) {
        if model.guides.zebras {
          Text(Self.zebraTitle(for: model.guides.validatedZebraPurpose)).fontWeight(.semibold)
          Text(Self.compactMeasurement(level: model.guides.zebraLevel, range: model.guides.zebraRange))
            .monospacedDigit()
        }
        if model.guides.falseColour { FalseColourKey(showsExplanation: false) }
        Text("Received picture (%)").foregroundStyle(Color.primary.opacity(0.75))
        DisclosureGroup("How to read this", isExpanded: $showsHelp) {
          ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
              ExposureGuidance(zebras: model.guides.zebras, guides: model.guides, falseColour: model.guides.falseColour)
              if model.guides.zebras {
                Text(Self.measurement(level: model.guides.zebraLevel, range: model.guides.zebraRange))
              }
              if model.guides.falseColour {
                Text(ExposureGuidance.colourAction).fontWeight(.semibold)
                Text("Grey shows brightness between these bands.")
                ForEach(ExposureGuidance.colourMeanings, id: \.self) { Text($0) }
              }
              Text("Skin tones vary; green and pink are not targets for every face. For flat picture settings, follow your camera's guidance.")
              Text("These guides show the received picture. They do not change your camera or saved video.")
            }.frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }.frame(maxHeight: 180 / zoom)
        }
      }.font(.callout).foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 480 / zoom, alignment: .leading)
        .padding(Space.sm)
        .background(Color(white: 0.12), in: .rect(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .uiZoom(zoom)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  static func compactMeasurement(level: Int, range: Int) -> String {
    range > 0 ? "Stripes: \(max(0, level - range))–\(min(100, level + range)) / 100"
      : "Stripes: \(level) and above / 100"
  }
}

/// Use the renderer's ranges, so the visible monitor key cannot drift from its colours.
struct FalseColourKey: View {
  var showsExplanation = true
  static let labels = ["Black", "Dark", "Mid", "Bright", "High", "White"]
  static func rangeLabel(_ range: ClosedRange<Double>) -> String {
    "\(range.lowerBound.formatted(.number.precision(.fractionLength(0...1))))–\(range.upperBound.formatted(.number.precision(.fractionLength(0...1))))%"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("Check brightness · False colour").fontWeight(.semibold)
      ViewThatFits(in: .horizontal) {
        bands(columns: 6)
        compactBands
      }
      if showsExplanation {
        Text("Grey shows brightness between these bands.")
          .foregroundStyle(Color.primary.opacity(0.75))
      }
    }.font(.callout).fixedSize(horizontal: false, vertical: true)
  }

  private var compactBands: some View {
    Grid(alignment: .leading, horizontalSpacing: Space.sm, verticalSpacing: Space.sm) {
      ForEach(0..<3, id: \.self) { row in
        GridRow {
          ForEach(0..<2, id: \.self) { column in
            let index = row * 2 + column
            let band = CameraExposure.bands[index]
            HStack(spacing: Space.xs) {
              Rectangle().fill(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
                .frame(width: Space.md, height: Space.md)
              Text(Self.labels[index])
              Text(Self.rangeLabel(band.range).dropLast()).monospacedDigit().foregroundStyle(Color.primary.opacity(0.75))
            }.fixedSize(horizontal: true, vertical: false)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("\(Self.labels[index]). \(band.name)")
              .accessibilityValue(Self.rangeLabel(band.range))
          }
        }
      }
    }
  }

  private func bands(columns: Int) -> some View {
    Grid(horizontalSpacing: Space.xs, verticalSpacing: Space.xs) {
      ForEach(0..<(6 / columns), id: \.self) { row in
        GridRow(alignment: .top) {
          ForEach(0..<columns, id: \.self) { column in
            let index = row * columns + column
            let band = CameraExposure.bands[index]
            VStack(spacing: Space.xs) {
              Rectangle().fill(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
                .frame(height: Space.md)
              Text(Self.labels[index])
              Text(Self.rangeLabel(band.range)).monospacedDigit().foregroundStyle(Color.primary.opacity(0.75))
            }.frame(minWidth: 68, maxWidth: .infinity)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("\(Self.labels[index]). \(band.name)")
              .accessibilityValue(Self.rangeLabel(band.range))
          }
        }
      }
    }
  }
}
