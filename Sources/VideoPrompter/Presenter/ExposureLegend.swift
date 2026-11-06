import SwiftUI

/// Meaning stays beside the monitor, numeric calibration stays in detailed help.
struct ExposureGuidance: View {
  let zebras: Bool
  let face: Bool
  let falseColour: Bool

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
        Text("Check bright areas: stripes mark the brightness range you chose. Lower brightness on your camera if important parts lose detail.")
        if face {
          Text("For faces, check detail on the lit cheek. Skin tones vary. If your camera uses a flat picture setting, follow its instructions. There is no single target for every face.")
        }
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
        if model.guides.zebras {
          DisclosureGroup("Zebras: selected brightness") {
            Text(Self.measurement(level: model.guides.zebraLevel, range: model.guides.zebraRange))
          }
        }
        ExposureGuidance(zebras: model.guides.zebras, face: model.guides.zebraLevel == 60 && model.guides.zebraRange == 5,
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
