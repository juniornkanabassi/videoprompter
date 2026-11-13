import Foundation

/// A three-way merge by lines. When the file changed outside the app while a presenter edit was
/// open, both changes are kept if they touch different lines; nil if they touch the same ones,
/// so the caller asks the person instead of choosing for them.
enum LineMerge {
  private struct Hunk: Equatable {
    var range: Range<Int>
    var lines: [String]
  }

  static func merge(base: String, mine: String, theirs: String) -> String? {
    if mine == theirs || theirs == base { return mine }
    if mine == base { return theirs }
    let original = lines(base)
    let mineHunks = hunks(from: original, to: lines(mine))
    let theirHunks = hunks(from: original, to: lines(theirs))
    for a in mineHunks {
      for b in theirHunks where a != b && clash(a, b) { return nil }
    }
    var all = mineHunks + theirHunks.filter { !mineHunks.contains($0) }
    // An insertion at the start of a replaced run goes first.
    all.sort { ($0.range.lowerBound, $0.range.isEmpty ? 0 : 1) < ($1.range.lowerBound, $1.range.isEmpty ? 0 : 1) }
    var merged: [String] = []
    var cursor = 0
    for hunk in all {
      merged += original[cursor..<hunk.range.lowerBound] + hunk.lines
      cursor = hunk.range.upperBound
    }
    merged += original[cursor...]
    return merged.joined(separator: "\n")
  }

  /// Ranges are half open, so neighbouring lines do not clash. Two insertions at one spot do (which
  /// comes first is a guess), and an insertion inside a replaced run does; one at its edge does not.
  private static func clash(_ a: Hunk, _ b: Hunk) -> Bool {
    switch (a.range.isEmpty, b.range.isEmpty) {
    case (true, true): return a.range.lowerBound == b.range.lowerBound
    case (true, false): return b.range.lowerBound < a.range.lowerBound && a.range.lowerBound < b.range.upperBound
    case (false, true): return clash(b, a)
    case (false, false): return a.range.lowerBound < b.range.upperBound && b.range.lowerBound < a.range.upperBound
    }
  }

  private static func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  /// The runs of `base` lines that `new` replaced, with what replaced them.
  private static func hunks(from base: [String], to new: [String]) -> [Hunk] {
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in new.difference(from: base) {
      switch change {
      case let .remove(offset, _, _): removed.insert(offset)
      case let .insert(offset, _, _): inserted.insert(offset)
      }
    }
    var result: [Hunk] = []
    var i = 0, j = 0
    while i < base.count || j < new.count {
      guard removed.contains(i) && i < base.count || inserted.contains(j) && j < new.count else { i += 1; j += 1; continue }
      let start = i
      var lines: [String] = []
      while (i < base.count && removed.contains(i)) || (j < new.count && inserted.contains(j)) {
        if i < base.count, removed.contains(i) { i += 1 } else { lines.append(new[j]); j += 1 }
      }
      result.append(Hunk(range: start..<i, lines: lines))
    }
    return result
  }
}
