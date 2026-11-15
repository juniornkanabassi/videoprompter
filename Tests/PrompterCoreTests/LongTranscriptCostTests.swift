import Foundation
import XCTest

@testable import PrompterCore

/// Parakeet sends one cumulative revision for a whole reading, so every result carries everything
/// said since Start. Matching it must not get slower as the reading goes on.
final class LongTranscriptCostTests: XCTestCase {
  /// Distinct pronounceable words ("bacade", "bacadi", ...), so the script never repeats itself.
  static func syntheticWords(_ count: Int) -> [String] {
    let consonants = Array("bcdfgklmnprstvz"), vowels = Array("aeiou")
    return (0..<count).map { n in
      var value = n + 1000, word = ""
      while value > 0 {
        word += String(consonants[value % consonants.count]) + String(vowels[(value / 3) % vowels.count])
        value /= consonants.count
      }
      return word
    }
  }

  func testMatchingCostStaysFlatOnALongCumulativeTranscript() {
    let script = Self.syntheticWords(2600)
    let tokens = PrompterDocument(markdown: script.joined(separator: " ")).spokenTokens
    // Every ninth word misheard as filler, so the tail is often not a clean continuation and the
    // general forward search runs, which is where the cost used to grow with the square.
    let heard = script.prefix(2100).enumerated().map { $0.offset % 9 == 4 ? "the" : $0.element }
    var tracker = RecognitionTracker(generation: 1)
    var cost: [Int: Double] = [:]
    for end in stride(from: 5, through: heard.count, by: 5) {
      let text = heard.prefix(end).joined(separator: " ")
      let started = ProcessInfo.processInfo.systemUptime
      _ = tracker.consume(.init(replacementID: "1-parakeet", generation: 1, text: text, isFinal: false,
        timestamp: Double(end), localeIdentifier: "en_GB", audioStart: 0, audioEnd: Double(end)), script: tokens)
      cost[end] = ProcessInfo.processInfo.systemUptime - started
    }
    func median(around words: Int) -> Double {
      let samples = cost.filter { abs($0.key - words) <= 50 }.map(\.value).sorted()
      return samples[samples.count / 2]
    }
    // Still following at the far end of the reading.
    XCTAssertGreaterThanOrEqual(tracker.tokenIndex, heard.count - 10)
    // Ten times the words. Re-parsing the text is linear; the old full-transcript search was about
    // twenty times slower here (12 ms to 268 ms a result in a debug build).
    let ratio = median(around: 2000) / median(around: 200)
    print("COST 200 words \(median(around: 200) * 1000) ms, 2,000 words \(median(around: 2000) * 1000) ms")
    XCTAssertLessThan(ratio, 8, "A result at 2,000 words cost \(ratio)× one at 200")
  }
}
