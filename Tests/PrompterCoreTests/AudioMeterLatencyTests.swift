import XCTest
import AVFoundation
import PrompterCore
@testable import VideoPrompter

@MainActor private final class LatencyResult { var old = 0.0; var new = 0.0 }

final class AudioMeterLatencyTests: XCTestCase {
  @MainActor func testCaptureDeliveryReachesSessionAndRemoteMeterWithinTarget() async throws {
    final class Pipe: LinkPipe, @unchecked Sendable {
      var messages: [Data] = []
      override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
        messages.append(data); done()
      }
    }
    let session = SessionStore(defaults: freshDefaults())
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    let pipe = Pipe(name: "meter-test")
    sender.pipe = pipe
    defer { sender.pipe = nil }
    sender.sampleMicLevel(session.meter)
    let published = expectation(description: "session meter published")
    let start = ProcessInfo.processInfo.systemUptime
    var local = 0.0
    let delivery = AudioMeterDelivery { levels in
      session.publishMeter(peak: levels[0], clipping: false)
      local = ProcessInfo.processInfo.systemUptime - start
      published.fulfill()
    }
    delivery.receive(peaks: [0.8], callback: start, capture: start)
    await fulfillment(of: [published], timeout: 1)
    XCTAssertEqual(sender.micMeter.levelDB, Double(session.meter.peakDBFS), accuracy: 0.001)
    for _ in 0..<100 where pipe.messages.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let message = try XCTUnwrap(pipe.messages.last)
    var reader = CameraLink.Reader()
    let decoded = try reader.append(message)
    guard case .command(.macStatus(let status)) = decoded.last else { return XCTFail("Expected a partial meter status") }
    XCTAssertEqual(try XCTUnwrap(status.micLevelDB), Double(session.meter.peakDBFS), accuracy: 0.001)
    XCTAssertNil(status.microphones, "A meter update must not enumerate sources")
    print(String(format: "METER callback to local=%.3f ms remote transport=%.3f ms (no physical network/display)", local * 1000, elapsed * 1000))
    XCTAssertLessThan(local, 0.05)
    XCTAssertLessThan(elapsed, 0.05)
  }

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

  @MainActor func testPendingAttackPublishesOnNextFrameWithoutAnotherBuffer() async {
    let first = expectation(description: "first frame")
    let next = expectation(description: "pending attack")
    var levels: [Float] = []
    var times: [Double] = []
    let meter = AudioMeterDelivery { value in
      levels.append(value[0]); times.append(ProcessInfo.processInfo.systemUptime)
      (levels.count == 1 ? first : next).fulfill()
    }
    meter.receive(peaks: [0.1], callback: ProcessInfo.processInfo.systemUptime)
    await fulfillment(of: [first], timeout: 1)
    meter.receive(peaks: [0.95], callback: ProcessInfo.processInfo.systemUptime)
    meter.receive(peaks: [0.1], callback: ProcessInfo.processInfo.systemUptime)
    await fulfillment(of: [next], timeout: 1)
    XCTAssertEqual(levels, [0.1, 0.95], "Keep the attack even if the last input is quiet")
    XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.015)
    XCTAssertLessThan(times[1] - times[0], 0.05)
    print(String(format: "METER pending attack=%.3f ms; no extra buffer required", (times[1] - times[0]) * 1000))
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
