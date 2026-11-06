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
          Text(Self.zebraPurpose(guides))
          Text(guides.zebraGuidance)
        }
      }
      if falseColour {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text(Self.colourPurpose)
          Text(Self.colourAction)
        }
      }
    }.font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
  }

  static func zebraPurpose(_ guides: CameraGuides) -> String {
    switch guides.validatedZebraPurpose {
    case .brightAreas: "Stripes show the brightest areas."
    case .faceReference: "Stripes mark your chosen face reference."
    case .custom: "Stripes show your chosen brightness range."
    }
  }
  static let colourPurpose = "Colours show dark, medium and bright areas in the received picture."
  static let colourAction = "Check dark and bright areas for detail. Adjust brightness on your camera, not here."
}

/// Shared settings rows keep each tool's purpose beside its switch, even when off.
struct ExposureToolToggles: View {
  @ObservedObject var model: CameraModel
  var body: some View {
    Toggle(isOn: $model.guides.zebras) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("Zebras").fontWeight(.semibold)
        Text(ExposureGuidance.zebraPurpose(model.guides))
      }
    }.accessibilityLabel("Zebras").accessibilityHint(ExposureGuidance.zebraPurpose(model.guides))
    Toggle(isOn: $model.guides.falseColour) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("False colour").fontWeight(.semibold)
        Text(ExposureGuidance.colourPurpose)
      }
    }.accessibilityLabel("False colour").accessibilityHint(ExposureGuidance.colourPurpose)
  }
}

struct ExposureLegend: View {
  @ObservedObject var model: CameraModel
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
      VStack(alignment: .leading, spacing: Space.md) {
        if model.guides.zebras {
          Text(Self.zebraTitle(for: model.guides.validatedZebraPurpose)).fontWeight(.semibold)
          ExposureGuidance(zebras: true, guides: model.guides, falseColour: false)
        }
        if model.guides.falseColour { FalseColourKey() }
        DisclosureGroup("Help") {
          VStack(alignment: .leading, spacing: Space.sm) {
            if model.guides.zebras {
              Text(Self.measurement(level: model.guides.zebraLevel, range: model.guides.zebraRange))
            }
            if model.guides.falseColour {
              ForEach(ExposureGuidance.colourMeanings, id: \.self) { Text($0) }
              Text("Grey areas fall between the coloured bands. Skin tones vary; green and pink are not targets for every face. For flat picture settings, follow your camera's guidance.")
            }
            Text("These guides show the received picture. They do not change your camera or saved video.")
          }.foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: 480, alignment: .leading).font(.callout).foregroundStyle(.primary).padding(Space.sm).modifier(PresenterGlass(radius: 12)).environment(\.colorScheme, .dark)
    }
  }
}

/// Use the renderer's ranges, so the visible monitor key cannot drift from its colours.
struct FalseColourKey: View {
  static let labels = ["Black", "Dark", "Mid", "Bright", "High", "White"]
  static func rangeLabel(_ range: ClosedRange<Double>) -> String {
    "\(range.lowerBound.formatted(.number.precision(.fractionLength(0...1))))–\(range.upperBound.formatted(.number.precision(.fractionLength(0...1))))%"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("Check brightness · False colour").fontWeight(.semibold)
      Text(ExposureGuidance.colourPurpose)
      HStack(alignment: .top, spacing: Space.xs) {
        ForEach(Array(CameraExposure.bands.enumerated()), id: \.offset) { index, band in
          VStack(spacing: Space.xs) {
            Rectangle().fill(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
              .frame(height: Space.md)
            Text(Self.labels[index])
            Text(Self.rangeLabel(band.range)).monospacedDigit().foregroundStyle(Color.primary.opacity(0.75))
          }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.labels[index]). \(band.name)")
            .accessibilityValue(Self.rangeLabel(band.range))
        }
      }
      Text("Grey shows brightness between these bands.")
        .foregroundStyle(Color.primary.opacity(0.75))
      Text(ExposureGuidance.colourAction)
    }.font(.callout).fixedSize(horizontal: false, vertical: true)
  }
}
