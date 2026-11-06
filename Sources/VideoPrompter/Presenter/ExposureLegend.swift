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
    VStack(alignment: .leading, spacing: Space.sm) {
      if zebras {
        Text(guides.zebraMeasurement)
        Text(guides.zebraGuidance)
      }
      if falseColour {
        Text("See brightness colours: purple and blue are dark; green and pink are brighter; yellow and red are very bright. Check the key before changing your camera.")
      }
    }.font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
  }
}

struct ExposureLegend: View {
  @ObservedObject var model: CameraModel
  static func measurement(level: Int, range: Int) -> String {
    range > 0
      ? "Stripes mark \(max(0, level - range))–\(min(100, level + range)) on a 0–100 brightness scale in the received picture."
      : "Stripes mark \(level) and above on a 0–100 brightness scale in the received picture."
  }

  var body: some View {
    if model.exposureIsConfigured && !model.cleanView && !model.exposureBypassed {
      VStack(alignment: .leading, spacing: Space.xs) {
        if model.guides.zebras { Text("Zebras · " + model.guides.validatedZebraPurpose.label) }
        ExposureGuidance(zebras: model.guides.zebras, guides: model.guides,
          falseColour: model.guides.falseColour)
        if model.guides.falseColour {
          DisclosureGroup("False colour key") {
            ForEach(Array(CameraExposure.bands.enumerated()), id: \.offset) { index, band in
              Label { Text(ExposureGuidance.colourMeanings[index]) } icon: {
                Image(systemName: "square.fill").foregroundStyle(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
              }
            }
          }
        }
      }.frame(maxWidth: 360, alignment: .leading).font(.callout).foregroundStyle(.primary).padding(Space.sm).modifier(PresenterGlass(radius: 12)).environment(\.colorScheme, .dark)
    }
  }
}
