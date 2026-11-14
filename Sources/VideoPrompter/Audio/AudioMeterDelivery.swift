@preconcurrency import AVFoundation
import Foundation

/// A single pending update retains peaks at up to 60 Hz without queuing stale readings.
final class AudioMeterDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [Float] = []
  private var scheduled = false
  private var oldestCallback = 0.0
  private var oldestCapture: Double?
  private var previousCallback: Double?
  private var lastDelivery: Double?
  private var envelope: [Float] = []
  private let onLevels: @MainActor @Sendable ([Float]) -> Void
  private let logsLatency = ProcessInfo.processInfo.environment["VIDEOPROMPTER_AUDIO_LATENCY"] == "1"

  init(onLevels: @escaping @MainActor @Sendable ([Float]) -> Void) { self.onLevels = onLevels }

  #if os(macOS)
  func receive(_ buffer: CMSampleBuffer, clock: CMClock? = nil) {
    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    if logsLatency {
      NSLog("Audio buffer: frames=%d duration=%.3f ms", CMSampleBufferGetNumSamples(buffer), CMSampleBufferGetDuration(buffer).seconds * 1000)
    }
    let capture = clock.map {
      CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(buffer), from: $0,
                        to: CMClockGetHostTimeClock()).seconds
    }
    receive(peaks: RecordingAudioTest.channelPeaks(in: buffer), callback: now, capture: capture)
  }

  #endif

  func receive(peaks: [Float], callback: Double, capture: Double? = nil) {
    lock.lock()
    // Instant attack, 20 dB/second release. Preserve a short transient until the UI consumes it.
    let decay = Float(pow(10, -max(0, callback - (previousCallback ?? callback))))
    previousCallback = callback
    envelope = peaks.enumerated().map { index, peak in
      max(peak, (index < envelope.count ? envelope[index] : 0) * decay)
    }
    if !scheduled { oldestCallback = callback; oldestCapture = capture }
    pending = envelope.enumerated().map { index, peak in max(peak, index < pending.count ? pending[index] : 0) }
    let enqueue = !scheduled
    let delay = max(0, 1.0 / 60 - (ProcessInfo.processInfo.systemUptime - (lastDelivery ?? -.infinity)))
    scheduled = true
    lock.unlock()
    guard enqueue else { return }
    Task { @MainActor [self] in
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      let value = lock.withLock { () -> ([Float], Double, Double?) in
        let value = (pending, oldestCallback, oldestCapture)
        pending = []; scheduled = false
        lastDelivery = ProcessInfo.processInfo.systemUptime
        return value
      }
      onLevels(value.0)
      if logsLatency {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let age = value.2.map { (now - $0) * 1000 } ?? .nan
        NSLog("Audio meter: callback-to-publish=%.3f ms capture-to-publish=%.3f ms", (now - value.1) * 1000, age)
      }
    }
  }
}
