import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testMicMeterQuietSpeechHotAndNoSignal() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let destination = URL(fileURLWithPath: output)
    let meter = InputMeter()
    let states: [(name: String, peak: Float?, clipping: Bool)] = [
      ("quiet", -48, false), ("speech", -14, false), ("hot", -2, true), ("nosignal", nil, false)
    ]
    for (mode, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != mode { continue }
      for state in states {
        meter.reset()
        if let peak = state.peak { meter.show(peakDBFS: peak, isClipping: state.clipping) }
        try await snapshot(MicMeterView(meter: meter, micName: "Built-in Microphone").frame(height: 420).padding(Space.md),
                           name: "mic-meter-\(state.name)-\(mode)", size: .init(width: 140, height: 452),
                           scheme: scheme, destination: destination)
      }
    }
    meter.reset()
  }
}
