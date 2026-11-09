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
    "Pink: brighter mid-tones. Check important areas still have detail.",
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
  var body: some View {
    Toggle(isOn: model.exposureBinding(\.zebras, presenter: presenter)) {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(ExposureLegend.zebraTitle(for: model.guides.validatedZebraPurpose)).fontWeight(.semibold)
        Text(ExposureGuidance.zebraPurpose(model.guides)).font(.callout)
      }
    }.initialPopoverFocus().accessibilityLabel(ExposureLegend.zebraTitle(for: model.guides.validatedZebraPurpose)).accessibilityHint(ExposureGuidance.zebraPurpose(model.guides))
    Toggle(isOn: model.exposureBinding(\.falseColour, presenter: presenter)) {
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
        ZebraSettings(guides: $model.guides)
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

/// Use the renderer's ranges, so the detailed key cannot drift from its colours.
struct FalseColourKey: View {
  var settings = CameraExposure.Settings()
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("False colour").fontWeight(.semibold)
      ForEach(Array(settings.legendBands.enumerated()), id: \.offset) { _, band in
        HStack {
          Rectangle().fill(Color(red: Double(band.colour & 255)/255, green: Double((band.colour >> 8) & 255)/255, blue: Double((band.colour >> 16) & 255)/255)).frame(width: Space.md, height: Space.md)
          Text(band.label)
          Spacer()
          Text(band.range + " IRE").monospacedDigit()
        }.accessibilityElement(children: .ignore)
          .accessibilityLabel(band.label).accessibilityValue(band.range + " IRE")
      }
      Text("Grey shows brightness between these bands.")
    }.font(.callout).fixedSize(horizontal: false, vertical: true)
  }
}


/// Shared by the HUD popover and Tools; zero width is the persisted Limit mode.
struct ZebraSettings: View {
  @Binding var guides: CameraGuides
  var onPreset: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Picker("Zebra mode", selection: $guides.zebraRangeMode) {
        Text("Limit").tag(false)
        Text("Range").tag(true)
      }.pickerStyle(.segmented)
      Stepper(value: $guides.zebraLevel, in: 0...100) {
        HStack {
          Text("Level")
          Spacer(minLength: Space.sm)
          Text("\(guides.zebraLevel) IRE").font(.title2.weight(.semibold)).monospacedDigit()
        }
      }
      if guides.zebraRangeMode {
        Stepper("Plus or minus: \(guides.zebraRange) IRE", value: $guides.zebraRange, in: 1...10)
      }
      HStack(spacing: Space.sm) {
        Button("My skin") {
          guides.useZebraPreset(.faceReference)
          onPreset()
        }
        Button("Highlights") { guides.useZebraPreset(.brightAreas); onPreset() }
      }
      Text(guides.exposure.zebraReadout).font(.callout)
    }
  }
}

/// A persistent corner key using the same skin-aware lookup table as the camera overlay.
struct ExposurePictureLegend: View {
  let settings: CameraExposure.Settings

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      if settings.zebras {
        HStack(spacing: Space.xs) {
          Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let path = CameraOverlay.zebraPath(picture: CGRect(origin: .zero, size: size))
            context.stroke(Path(path), with: .color(.black), lineWidth: 2)
          }
          .frame(width: Space.lg * 2, height: Space.lg)
          .clipped()
          .accessibilityHidden(true)
          Text(settings.zebraLegend)
        }
      }
      if settings.falseColour {
        ViewThatFits(in: .horizontal) {
          Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
            ForEach(0..<2) { row in
              GridRow {
                ForEach(0..<3) { column in
                  let index = row * 3 + column
                  if index < settings.legendBands.count { bandView(settings.legendBands[index], stacked: true) }
                }
              }
            }
          }.fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(Array(settings.legendBands.enumerated()), id: \.offset) { _, band in
              bandView(band)
            }
          }
        }
      }
    }
    .font(.system(size: 16, weight: .semibold))
    .foregroundStyle(.white)
    .fixedSize(horizontal: false, vertical: true)
    .padding(Space.md)
    .background(.black.opacity(0.94), in: .rect(cornerRadius: Space.sm))
    .overlay(RoundedRectangle(cornerRadius: Space.sm).strokeBorder(.white.opacity(0.25), lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Exposure legend")
    .allowsHitTesting(false)
  }

  private func bandView(_ band: CameraExposure.LegendBand, stacked: Bool = false) -> some View {
    let swatch = Rectangle()
      .fill(Color(red: Double(band.colour & 255) / 255,
                  green: Double((band.colour >> 8) & 255) / 255,
                  blue: Double((band.colour >> 16) & 255) / 255))
      .frame(width: Space.lg * 2, height: Space.lg)
      .accessibilityHidden(true)
    let label = VStack(alignment: .leading, spacing: Space.xs) {
      Text(band.label)
      Text(band.range + " IRE").monospacedDigit()
    }
    return Group {
      if stacked {
        VStack(alignment: .leading, spacing: Space.xs) { swatch; label }
      } else {
        HStack(spacing: Space.sm) { swatch; label }
      }
    }.fixedSize(horizontal: true, vertical: true)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(band.label), \(band.range) IRE")
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
            Canvas { context, size in
              context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
              context.stroke(Path(CameraOverlay.zebraPath(picture: CGRect(origin: .zero, size: size))), with: .color(.black), lineWidth: 2)
            }.frame(width: 44, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading) {
              Text("Zebras").font(.system(size: 19, weight: .semibold))
              Text(guides.exposure.zebraRangeLabel + " IRE").font(.system(size: 15)).foregroundStyle(.secondary)
            }
          }
        }
        if guides.falseColour {
          ForEach(Array(guides.exposure.legendBands.reversed().sorted { ($0.label == "My skin" ? 0 : 1) < ($1.label == "My skin" ? 0 : 1) }.enumerated()), id: \.offset) { _, band in
            HStack(spacing: 16) {
              RoundedRectangle(cornerRadius: 4).fill(Color(red: Double(band.colour & 255)/255, green: Double((band.colour >> 8) & 255)/255, blue: Double((band.colour >> 16) & 255)/255)).frame(width: 44, height: 28)
              VStack(alignment: .leading) {
                Text(band.label).font(.system(size: 19, weight: .semibold))
                Text(band.range + " IRE").font(.system(size: 15)).foregroundStyle(.secondary)
              }
            }
          }
        }
        Text("Measured from the incoming picture.").font(.system(size: 13)).foregroundStyle(.secondary)
      }
    }.padding(16).foregroundStyle(.white).background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
      .environment(\.colorScheme, .dark).uiZoom(zoom)
  }
}

struct ZebraAdjustView: View {
  @Binding var guides: CameraGuides
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Zebras").font(.title2.bold())
      Text("Stripes show where the picture is at a brightness you choose.").foregroundStyle(.secondary)
      HStack(spacing: 12) {
        preset("My skin", detail: "Range · \(guides.skinReference.level) ±\(guides.skinReference.range) IRE", purpose: .faceReference)
        preset("Highlights", detail: "Limit · 95 IRE and up", purpose: .brightAreas)
      }
      Picker("Mode", selection: $guides.zebraRangeMode) { Text("Range").tag(true); Text("Limit").tag(false) }.pickerStyle(.segmented)
      ExposureNumberRow(title: "Level", value: $guides.zebraLevel, limits: 0...100, suffix: " IRE")
      if guides.zebraRangeMode { ExposureNumberRow(title: "Plus or minus", value: $guides.zebraRange, limits: 1...10, prefix: "±") }
      Text(guides.exposure.zebraReadout).fontWeight(.semibold)
      Text("Each mode keeps its own values. Skin in false colour is set separately.").foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func preset(_ title: String, detail: String, purpose: CameraGuides.ZebraPurpose) -> some View {
    Button { guides.useZebraPreset(purpose) } label: {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(guides.validatedZebraPurpose == purpose ? Color.accentColor : .clear, lineWidth: 2))
    }.buttonStyle(.plain)
      .accessibilityValue(guides.validatedZebraPurpose == purpose ? "Selected" : "")
  }
}

private struct ExposureNumberRow: View {
  let title: String
  @Binding var value: Int
  let limits: ClosedRange<Int>
  var prefix = ""
  var suffix = ""
  var body: some View {
    HStack {
      Text(title); Spacer()
      Button { value = max(limits.lowerBound, value - 1) } label: { Text("−").frame(minWidth: 46, minHeight: 46).contentShape(Rectangle()) }.accessibilityLabel("Decrease \(title)") // grid: ok specified target
      Text("\(prefix)\(value)\(suffix)").font(.title2.bold()).monospacedDigit().frame(minWidth: 88)
      Button { value = min(limits.upperBound, value + 1) } label: { Text("+").frame(minWidth: 46, minHeight: 46).contentShape(Rectangle()) }.accessibilityLabel("Increase \(title)") // grid: ok specified target
    }
  }
}

private struct TonePicture: View {
  let name: String
  var body: some View {
    let bundled = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "SkinTones")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fallback = root.appendingPathComponent("Resources/SkinTones/\(name).png")
    if let image = NSImage(contentsOf: bundled ?? fallback) {
      Image(nsImage: image).resizable().scaledToFill().clipped()
    } else {
      Color.gray
    }
  }
}

struct SkinTonePicker: View {
  @Binding var guides: CameraGuides
  @State private var customSelected = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Skin tone").font(.headline)
      Text("Pick the face closest to yours. Pink in false colour and the My skin zebras show where your skin should sit.").foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
        ForEach(CameraGuides.SkinTone.allCases, id: \.self) { tone in
          let selected = tone == .custom ? customSelected || guides.skinTone == .custom : !customSelected && guides.skinTone == tone
          Button {
            customSelected = tone == .custom
            if let reference = tone.reference { guides.skinReference = reference }
          } label: {
            VStack(spacing: 4) {
              Group {
                if tone == .custom {
                  Image(systemName: "slider.horizontal.3").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.2))
                } else { TonePicture(name: tone.rawValue.lowercased()) }
              }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
              Text(tone.rawValue).font(.callout.bold()).lineLimit(1).minimumScaleFactor(0.8)
              if let ref = tone.reference { Text("\(ref.level) ±\(ref.range) IRE").font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
              else { Text("Set your own").font(.caption2) }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .top).padding(8)
              .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
          }.buttonStyle(.plain)
            .accessibilityLabel(tone.reference.map { "\(tone.rawValue) skin tone, \($0.level) plus or minus \($0.range) IRE" } ?? "Custom skin tone")
            .accessibilityValue(selected ? "Selected" : "")
        }
      }
      if customSelected || guides.skinTone == .custom {
        ExposureNumberRow(title: "Level", value: $guides.skinReference.level, limits: 0...100, suffix: " IRE")
        ExposureNumberRow(title: "Plus or minus", value: $guides.skinReference.range, limits: 1...10, prefix: "±")
      }
      Text(guides.greyCardCheck ? "Green shows the grey card at 39 to 43 IRE" : "Pink shows skin at \(max(0, guides.skinReference.level - guides.skinReference.range)) to \(min(100, guides.skinReference.level + guides.skinReference.range)) IRE")
        .font(.callout.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }.disabled(guides.greyCardCheck)
  }
}

struct FalseColourAdjustView: View {
  @Binding var guides: CameraGuides
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Toggle("False colour", isOn: $guides.falseColour).disabled(guides.greyCardCheck)
      SkinTonePicker(guides: $guides)
      HStack(alignment: .top, spacing: 12) {
        TonePicture(name: "greycard").frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Grey card check", isOn: $guides.greyCardCheck).font(.headline)
          Text("Hold an 18% grey card where your face will be. Adjust exposure until the card turns green (Mid grey, 41 IRE). Turn this off to go back to your skin settings.").font(.callout).foregroundStyle(.secondary)
        }
      }.padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
      FalseColourKey(settings: guides.exposure)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
