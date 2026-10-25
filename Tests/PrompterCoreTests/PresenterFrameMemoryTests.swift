import AppKit
import XCTest
@testable import VideoPrompter

final class PresenterFrameMemoryTests: XCTestCase {
  private let main = PresenterFrameMemory.Screen(id: 1, name: "N07", frame: NSRect(x: 0, y: 0, width: 2304, height: 1296), visibleFrame: NSRect(x: 0, y: 0, width: 2304, height: 1266))
  private let prompter = PresenterFrameMemory.Screen(id: 7, name: "Prompter XL", frame: NSRect(x: 2304, y: 216, width: 1920, height: 1080), visibleFrame: NSRect(x: 2304, y: 216, width: 1920, height: 1080))

  private func defaults() -> UserDefaults {
    let suite = "VideoPrompter.frame.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    return UserDefaults(suiteName: suite)!
  }

  func testAFrameOnThePrompterDisplayComesBackThere() {
    let store = defaults()
    let frame = NSRect(x: 2600, y: 656, width: 760, height: 520)
    PresenterFrameMemory.save(frame, on: prompter, to: store)
    XCTAssertEqual(PresenterFrameMemory.restored(from: store, screens: [main, prompter]), frame)
  }

  func testTheDisplayIsFoundByNameWhenItsIDChanged() {
    let store = defaults()
    PresenterFrameMemory.save(NSRect(x: 2600, y: 656, width: 760, height: 520), on: prompter, to: store)
    let reconnected = PresenterFrameMemory.Screen(id: 9, name: prompter.name, frame: prompter.frame, visibleFrame: prompter.visibleFrame)
    XCTAssertNotNil(PresenterFrameMemory.restored(from: store, screens: [main, reconnected]))
  }

  func testAMissingDisplayRestoresNothing() {
    let store = defaults()
    PresenterFrameMemory.save(NSRect(x: 2600, y: 656, width: 760, height: 520), on: prompter, to: store)
    XCTAssertNil(PresenterFrameMemory.restored(from: store, screens: [main]))
    XCTAssertNil(PresenterFrameMemory.restored(from: nil, screens: [main, prompter]))
  }

  func testAFrameOverTheTopIsMovedInsideTheVisibleArea() {
    let clamped = PresenterFrameMemory.clamp(NSRect(x: 2400, y: 400, width: 1400, height: 1050), into: prompter.visibleFrame)
    XCTAssertEqual(clamped.maxY, prompter.visibleFrame.maxY)
    XCTAssertEqual(clamped.size, NSSize(width: 1400, height: 1050))
    let tooBig = PresenterFrameMemory.clamp(NSRect(x: 0, y: 0, width: 5000, height: 3000), into: main.visibleFrame)
    XCTAssertEqual(tooBig, main.visibleFrame)
  }
}
