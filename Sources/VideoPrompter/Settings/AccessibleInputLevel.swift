import AppKit
import SwiftUI

struct AccessibleInputLevel: NSViewRepresentable {
  let peakDBFS: Float
  let isClipping: Bool
  static func description(peakDBFS: Float, isClipping: Bool) -> String {
    let state = isClipping ? "Clipping. Lower Microphone volume" : (!peakDBFS.isFinite || peakDBFS < -60 ? "No sound" : "Receiving sound")
    return peakDBFS.isFinite ? state + String(format: ", %.1f dBFS", peakDBFS) : state
  }
  func makeNSView(context: Context) -> NSLevelIndicator {
    let view = NSLevelIndicator()
    view.minValue = -60; view.maxValue = 0
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.levelIndicator)
    view.setAccessibilityLabel("Microphone peak level")
    // Only its accessibility element is needed; the existing meter draws the visual scale.
    view.levelIndicatorStyle = .continuousCapacity
    return view
  }
  func updateNSView(_ view: NSLevelIndicator, context: Context) {
    view.doubleValue = peakDBFS.isFinite ? min(0, max(-60, Double(peakDBFS))) : -60
    view.setAccessibilityValueDescription(Self.description(peakDBFS: peakDBFS, isClipping: isClipping))
    view.setAccessibilityHelp("Live microphone level. Check for sound before recording.")
    view.isHidden = false
    view.alphaValue = 0.01
  }
}
