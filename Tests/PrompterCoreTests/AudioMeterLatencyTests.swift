import XCTest
import AVFoundation
@testable import VideoPrompter

@MainActor private final class LatencyResult { var old = 0.0; var new = 0.0 }

final class AudioMeterLatencyTests: XCTestCase {
  @MainActor func testCoalescesWithoutLosingStereoTransient() async {
    let delivered = expectation(description: "meter published")
    var values: [[Float]] = []
    let meter = AudioMeterDelivery { peaks in values.append(peaks); delivered.fulfill() }
    meter.receive(peaks: [0.9, 0.1], callback: 1)
    meter.receive(peaks: [0.1, 0.8], callback: 1.01)
    await fulfillment(of: [delivered], timeout: 1)
    XCTAssertEqual(values.count, 1)
    XCTAssertEqual(values[0], [0.9, 0.8])
  }

  @MainActor func testReleaseAndImmediateAttack() async {
    let first = expectation(description: "first")
    let second = expectation(description: "release")
    let third = expectation(description: "attack")
    var values: [Float] = []
    let meter = AudioMeterDelivery { peaks in
      values.append(peaks[0])
      [first, second, third][values.count - 1].fulfill()
    }
    meter.receive(peaks: [1], callback: 1)
    await fulfillment(of: [first], timeout: 1)
    meter.receive(peaks: [0], callback: 1.5)
    await fulfillment(of: [second], timeout: 1)
    meter.receive(peaks: [1], callback: 1.501)
    await fulfillment(of: [third], timeout: 1)
    XCTAssertEqual(values[1], pow(10, -0.5), accuracy: 0.0001)
    XCTAssertEqual(values[2], 1)
  }

  @MainActor func testMeterDoesNotWaitForBusyWriterQueue() async {
    let writer = DispatchQueue(label: "synthetic-busy-writer")
    let blockerStarted = expectation(description: "writer busy")
    writer.async { blockerStarted.fulfill(); Thread.sleep(forTimeInterval: 0.08) }
    await fulfillment(of: [blockerStarted], timeout: 1)
    let before = expectation(description: "old shared queue")
    let after = expectation(description: "separate meter")
    let start = ProcessInfo.processInfo.systemUptime
    let result = LatencyResult()
    writer.async {
      Task { @MainActor in result.old = ProcessInfo.processInfo.systemUptime - start; before.fulfill() }
    }
    let meter = AudioMeterDelivery { _ in result.new = ProcessInfo.processInfo.systemUptime - start; after.fulfill() }
    meter.receive(peaks: [0.8, 0.4], callback: start)
    await fulfillment(of: [before, after], timeout: 2)
    print(String(format: "SYNTHETIC callback-to-publish before=%.3f ms after=%.3f ms", result.old * 1000, result.new * 1000))
    XCTAssertGreaterThanOrEqual(result.old, 0.07)
    XCTAssertLessThan(result.new, result.old)
  }
}
