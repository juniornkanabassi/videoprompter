import PrompterCore
import SwiftUI

/// The right-click menus for Zebras and False colour. One representation drives the Mac's own camera
/// and a remote iPad: the exposure state as `PadRemote.Guides`, and every choice as the partial
/// `PadRemote.Guides` update the iPad already understands. Ticks and values come from that state only.
enum ExposureMenuLogic {
  static let levels = [40, 45, 50, 55, 60, 70, 80, 90, 95, 100]
  static let widths = [1, 2, 3, 5, 10]

  static func clamp(_ level: Int) -> Int { min(100, max(0, level)) }
  static func band(_ level: Int, _ range: Int) -> String { range > 0 ? "\(level) ±\(range)" : "\(level)+" }
  static func spoken(_ level: Int, _ range: Int) -> String {
    range > 0 ? "\(level) plus or minus \(range) IRE" : "\(level) IRE and up"
  }

  // MARK: Menu choice to update

  static func purposeUpdate(_ purpose: CameraGuides.ZebraPurpose) -> PadRemote.Guides {
    .init(zebras: true, zebraPurpose: purpose.rawValue)
  }
  static func levelUpdate(_ level: Int) -> PadRemote.Guides { .init(zebras: true, zebraLevel: clamp(level)) }
  static func widthUpdate(_ width: Int) -> PadRemote.Guides { .init(zebras: true, zebraRange: min(10, max(1, width))) }
  /// "A level and brighter" or "Near a level": the mode alone, so the receiver restores that mode's own saved level and width.
  static func modeUpdate(near: Bool, state: PadRemote.Guides) -> PadRemote.Guides {
    .init(zebras: true, zebraRangeMode: near)
  }
  /// Custom… selects the custom tone (keeping the current numbers) before Adjust opens on its steppers.
  static func customSkinUpdate(_ state: PadRemote.Guides) -> PadRemote.Guides {
    .init(falseColour: true, skinLevel: state.skinLevel)
  }
  static func skinToneUpdate(_ tone: CameraGuides.SkinTone) -> PadRemote.Guides {
    .init(falseColour: true, skinTone: tone.rawValue)
  }
  static func greyCardUpdate(_ on: Bool) -> PadRemote.Guides { .init(greyCardCheck: on) }

  // MARK: Summaries (key strip labels)

  static func zebraSummary(_ state: PadRemote.Guides) -> String {
    guard state.zebras == true else { return "off" }
    let level = state.zebraLevel ?? 0, range = state.zebraRange ?? 0
    switch CameraGuides.ZebraPurpose(rawValue: state.zebraPurpose ?? "") {
    case .faceReference: return "My skin · \(band(level, range))"
    case .brightAreas: return "Highlights · \(level)+"
    default: return "Custom · \(band(level, range))"
    }
  }
  static func colourSummary(_ state: PadRemote.Guides) -> String {
    guard state.falseColour == true else { return "off" }
    if state.greyCardCheck == true { return "Grey card · 41 ±2" }
    return "\(state.skinTone ?? "Custom") · \(band(state.skinLevel ?? 0, state.skinRange ?? 1))"
  }

  // MARK: The Mac's own camera

  /// Mirrors what the iPad reports about itself (`PadStore.remoteState`).
  static func state(from guides: CameraGuides) -> PadRemote.Guides {
    .init(zebras: guides.zebras, falseColour: guides.falseColour,
      zebraPurpose: guides.validatedZebraPurpose.rawValue, zebraLevel: guides.zebraLevel, zebraRange: guides.zebraRange,
      skinTone: guides.skinTone.rawValue, skinLevel: guides.skinReference.level, skinRange: guides.skinReference.range,
      greyCardCheck: guides.greyCardCheck)
  }

  /// Applies an update the way the iPad does (`PadStore.perform(.cameraGuides)`): a manual change ends
  /// a grey card check, and a new check starts last. Switching an aid off leaves bypass and Clean view alone.
  @MainActor static func apply(_ update: PadRemote.Guides, to model: CameraModel) {
    var rest = update
    rest.greyCardCheck = nil
    if rest != PadRemote.Guides() {
      let kept = (model.exposureBypassed, model.cleanView)
      model.changeExposure { guides in
        if let value = rest.zebras { guides.zebras = value }
        if let value = rest.falseColour { guides.falseColour = value }
        guides.applyExposure(rest)
      }
      if rest.zebras == false || rest.falseColour == false { (model.exposureBypassed, model.cleanView) = kept }
    }
    if let on = update.greyCardCheck { model.setGreyCardCheck(on) }
  }

  // MARK: A remote iPad, for the Adjust panels

  /// The iPad's reported state as `CameraGuides`, so the shared Adjust panels can show it. The panels'
  /// saved-range values start from the skin reference, the same width "Near a level" uses.
  static func guides(from state: PadRemote.Guides) -> CameraGuides {
    var guides = CameraGuides()
    guides.zebras = state.zebras ?? false
    guides.falseColour = state.falseColour ?? false
    guides.skinReference = .init(level: state.skinLevel ?? guides.skinReference.level, range: state.skinRange ?? guides.skinReference.range)
    guides.savedRangeLevel = guides.skinReference.level; guides.savedRangeWidth = guides.skinReference.range
    guides.zebraLevel = state.zebraLevel ?? guides.zebraLevel
    guides.zebraRange = state.zebraRange ?? guides.zebraRange
    // Level and range reset the purpose, so it is set after them, and the tone after the reference.
    if let purpose = state.zebraPurpose.flatMap(CameraGuides.ZebraPurpose.init(rawValue:)) { guides.zebraPurpose = purpose }
    guides.selectedSkinTone = state.skinTone.flatMap(CameraGuides.SkinTone.init(rawValue:))
    if state.greyCardCheck == true {
      // Placeholder values equal to the current ones: finishing the check changes nothing but the check.
      guides.greyCardRestore = .init(skin: guides.skinReference, zebras: guides.zebras, level: guides.zebraLevel, range: guides.zebraRange,
        purpose: guides.zebraPurpose, savedRangeLevel: guides.savedRangeLevel, savedRangeWidth: guides.savedRangeWidth,
        savedLimitLevel: guides.savedLimitLevel, falseColour: guides.falseColour)
    }
    return guides
  }

  /// Only what the panel changed, as an update. A preset sends only its name, because the receiver
  /// works out the preset's numbers; a Limit/Range switch sends only the width for the same reason.
  static func update(from old: CameraGuides, to new: CameraGuides) -> PadRemote.Guides {
    var old = old
    var update = PadRemote.Guides()
    if new.greyCardCheck != old.greyCardCheck {
      if new.greyCardCheck { return greyCardUpdate(true) }
      old.greyCardCheck = false
      update.greyCardCheck = false
    }
    if new.zebras != old.zebras { update.zebras = new.zebras }
    if new.falseColour != old.falseColour { update.falseColour = new.falseColour }
    let before = old.validatedZebraPurpose, after = new.validatedZebraPurpose
    if after != before && after != .custom {
      update.zebraPurpose = after.rawValue
    } else if !(before == .faceReference && after == .faceReference) {
      if after != before { update.zebraPurpose = after.rawValue }
      if new.zebraRangeMode != old.zebraRangeMode { update.zebraRangeMode = new.zebraRangeMode }
      else {
        if new.zebraRange != old.zebraRange { update.zebraRange = new.zebraRange }
        if new.zebraLevel != old.zebraLevel { update.zebraLevel = new.zebraLevel }
      }
    }
    let skinChanged = new.skinReference != old.skinReference
    if skinChanged || new.skinTone != old.skinTone {
      if new.skinTone == .custom && skinChanged {
        if new.skinReference.level != old.skinReference.level { update.skinLevel = new.skinReference.level }
        if new.skinReference.range != old.skinReference.range { update.skinRange = new.skinReference.range }
      } else {
        update.skinTone = new.skinTone.rawValue
      }
    }
    return update
  }
}

/// Shared by every host. `enabled` greys the choices (iPad not connected); an iPad app that does not
/// report levels gets only the on and off switch.
struct ZebraMenuContent: View {
  let guides: PadRemote.Guides
  var title: String? = nil
  var enabled = true
  let send: (PadRemote.Guides) -> Void
  let adjust: () -> Void

  private var level: Int { guides.zebraLevel ?? 0 }
  private var range: Int { guides.zebraRange ?? 0 }
  private var purpose: CameraGuides.ZebraPurpose? { CameraGuides.ZebraPurpose(rawValue: guides.zebraPurpose ?? "") }

  private func choice(_ title: String, spoken: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
    Toggle(title, isOn: Binding(get: { on }, set: { _ in action() })).accessibilityLabel(spoken ?? title).disabled(!enabled)
  }

  var body: some View {
    if let title { Text(title); Divider() }
    Toggle("Zebras", isOn: Binding(get: { guides.zebras ?? false }, set: { send(.init(zebras: $0)) })).disabled(!enabled)
    if guides.zebraLevel == nil {
      Divider()
      Text("Update the iPad app to change levels from here")
    } else {
      Section("Show stripes on") {
        choice("My skin · \(ExposureMenuLogic.band(guides.skinLevel ?? 0, guides.skinRange ?? 0)) IRE",
          spoken: "My skin, \(ExposureMenuLogic.spoken(guides.skinLevel ?? 0, guides.skinRange ?? 0))", on: purpose == .faceReference) {
          send(ExposureMenuLogic.purposeUpdate(.faceReference))
        }
        choice("Highlights · 95 IRE and up", on: purpose == .brightAreas) { send(ExposureMenuLogic.purposeUpdate(.brightAreas)) }
        if purpose == .custom {
          choice("Custom · \(ExposureMenuLogic.band(level, range)) IRE", spoken: "Custom, \(ExposureMenuLogic.spoken(level, range))", on: true) {}
        } else {
          Button("Custom…", action: adjust).disabled(!enabled)
        }
      }
      Divider()
      choice("Near a level", on: range > 0) { send(ExposureMenuLogic.modeUpdate(near: true, state: guides)) }
      choice("A level and brighter", on: range == 0) { send(ExposureMenuLogic.modeUpdate(near: false, state: guides)) }
      Divider()
      Menu("Level · \(level) IRE") {
        ForEach(Set(ExposureMenuLogic.levels + [level]).sorted(), id: \.self) { value in
          choice("\(value) IRE", on: value == level) { send(ExposureMenuLogic.levelUpdate(value)) }
        }
        Divider()
        Button("Up 1") { send(ExposureMenuLogic.levelUpdate(level + 1)) }.disabled(level >= 100)
        Button("Down 1") { send(ExposureMenuLogic.levelUpdate(level - 1)) }.disabled(level <= 0)
      }.disabled(!enabled)
      Menu(range > 0 ? "Width · ±\(range) IRE" : "Width") {
        ForEach(Set(ExposureMenuLogic.widths + [range]).sorted().filter { $0 > 0 }, id: \.self) { value in
          choice("±\(value)", spoken: "Plus or minus \(value) IRE", on: value == range) { send(ExposureMenuLogic.widthUpdate(value)) }
        }
      }.disabled(!enabled || range == 0)
      Divider()
      Button("Adjust zebras…", action: adjust).disabled(!enabled)
    }
  }
}

struct FalseColourMenuContent: View {
  let guides: PadRemote.Guides
  var title: String? = nil
  var enabled = true
  let send: (PadRemote.Guides) -> Void
  let adjust: () -> Void

  private var checking: Bool { guides.greyCardCheck == true }

  private func choice(_ title: String, spoken: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
    Toggle(title, isOn: Binding(get: { on }, set: { _ in action() })).accessibilityLabel(spoken ?? title)
  }

  var body: some View {
    if let title { Text(title); Divider() }
    Toggle("False colour", isOn: Binding(get: { guides.falseColour ?? false }, set: { send(.init(falseColour: $0)) })).disabled(!enabled)
    if guides.skinLevel == nil {
      Divider()
      Text("Update the iPad app to change levels from here")
    } else {
      Section("My skin tone (shows in pink, also moves My skin zebras)") {
        ForEach(CameraGuides.SkinTone.allCases, id: \.self) { tone in
          if let reference = tone.reference {
            choice("\(tone.rawValue) · \(reference.level) ±\(reference.range) IRE",
              spoken: "\(tone.rawValue), \(ExposureMenuLogic.spoken(reference.level, reference.range))",
              on: guides.skinTone == tone.rawValue) { send(ExposureMenuLogic.skinToneUpdate(tone)) }
          }
        }
        choice("Custom…", on: guides.skinTone == CameraGuides.SkinTone.custom.rawValue) { send(ExposureMenuLogic.customSkinUpdate(guides)); adjust() }
      }.disabled(!enabled || checking)
      Divider()
      if checking {
        choice("Grey card check · 41 ±2 IRE", spoken: "Grey card check, 41 plus or minus 2 IRE", on: true) {}.disabled(!enabled)
        Button("Finish grey card check") { send(ExposureMenuLogic.greyCardUpdate(false)) }.disabled(!enabled)
      } else {
        Button("Start grey card check") { send(ExposureMenuLogic.greyCardUpdate(true)) }.disabled(!enabled)
      }
      Divider()
      Button("Adjust false colour…", action: adjust).disabled(!enabled)
    }
  }
}

extension ZebraMenuContent {
  /// The Mac's own camera.
  init(model: CameraModel, adjust: @escaping () -> Void) {
    self.init(guides: ExposureMenuLogic.state(from: model.guides), send: { ExposureMenuLogic.apply($0, to: model) }, adjust: adjust)
  }
}

extension FalseColourMenuContent {
  init(model: CameraModel, adjust: @escaping () -> Void) {
    self.init(guides: ExposureMenuLogic.state(from: model.guides), send: { ExposureMenuLogic.apply($0, to: model) }, adjust: adjust)
  }
}
