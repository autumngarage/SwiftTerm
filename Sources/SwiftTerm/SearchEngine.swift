//
//  SearchEngine.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

import Foundation

struct SearchResult: Equatable {
    let term: String
    let col: Int
    let row: Int
    let size: Int
}

struct SearchSelection {
    let start: Position
    let end: Position
}

final class SearchEngine {
    private let terminal: Terminal
    private let lineCache: SearchLineCache
    private let nonWordCharacters: Set<Character> = Set(" ~!@#$%^&*()+`-=[]{}|\\;:\"',./<>?")
    /// The last compiled pattern, kept because `findInLine` is re-entered per
    /// row of every scan and per candidate on the boundary line — so a regex
    /// search recompiled the same pattern hundreds of times per keystroke,
    /// synchronously on the main actor. One entry is enough: a search uses one
    /// pattern at a time.
    private var compiledPattern: (pattern: String, caseSensitive: Bool, regex: NSRegularExpression)?

    /// A search window is a view into the line, not a line of its own.
    ///
    /// Every search here runs over a sub-range — from a previous selection,
    /// from the viewport edge, or from past the last candidate — and by
    /// default `NSRegularExpression` treats that range as the whole world.
    /// Two consequences, and both were wrong:
    ///
    /// - **Anchoring.** `^` and `$` bound to the range, so `^x` matched at
    ///   whatever offset the search resumed from, and the boundary walk —
    ///   which restarts after each rejected candidate — produced a fresh
    ///   "start of line" match at every step.
    /// - **Opaque bounds.** Lookbehind and lookahead could not see past the
    ///   range, so `(?<=x)x` on `xxx` skipped the match at column 2: the `x`
    ///   it needed to look back at had just been excluded by the restart.
    ///
    /// Together these say "match only inside the window, but read the whole
    /// line while deciding" — which is what a window into a line means.
    private static let subrangeMatching: NSRegularExpression.MatchingOptions =
        [.withoutAnchoringBounds, .withTransparentBounds]

    private func regex(for pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        if let cached = compiledPattern,
           cached.pattern == pattern, cached.caseSensitive == caseSensitive {
            return cached.regex
        }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        compiledPattern = (pattern, caseSensitive, compiled)
        return compiled
    }

    init (terminal: Terminal, lineCache: SearchLineCache) {
        self.terminal = terminal
        self.lineCache = lineCache
    }

    func find (term: String, startRow: Int, startCol: Int, searchOptions: SearchOptions? = nil) -> SearchResult? {
        if term.isEmpty {
            return nil
        }
        if startCol > terminal.cols {
            return nil
        }

        lineCache.initLinesCache()

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)

        var result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
        if result == nil {
            let maxRow = terminal.displayBuffer.lines.count
            if startRow + 1 < maxRow {
                for y in (startRow + 1)..<maxRow {
                    searchPosition.startRow = y
                    searchPosition.startCol = 0
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                    if result != nil {
                        break
                    }
                }
            }
        }
        return result
    }

    func findNextWithSelection (term: String, searchOptions: SearchOptions? = nil, cachedSearchTerm: String?, previousSelection: SearchSelection?) -> SearchResult? {
        if term.isEmpty {
            return nil
        }

        lineCache.initLinesCache()

        var startCol = 0
        var startRow = 0
        // "Resume" only means something when the query is unchanged — pressing
        // Enter or Cmd+G to walk the matches. A *different* term is a new
        // question, and live search asks it on every keystroke: with an
        // earlier selection still set, seeding from it starts the scan below
        // that point, wraps to row 0, and lands on the oldest match while an
        // on-screen one sits just above. Anchoring the first hit of any new
        // term to the viewport is what iTerm2 and Terminal.app do.
        let isNewQuery = previousSelection == nil || cachedSearchTerm != term
        if isNewQuery {
            if let nearest = findNearestAtOrAboveViewport(
                term: term,
                searchOptions: searchOptions
            ) {
                return nearest
            }
            // Nothing at or above the viewport — and after that scan, that is
            // PROVED for every row from 0 through `viewportBottomRow`. So the
            // only region left to search is below it, and once that is done
            // the whole buffer has been covered exactly once: there is nothing
            // to wrap around to, and the answer below is final.
            //
            // Falling through to the general path instead would re-scan the
            // rows just cleared — once in the forward loop from row 0, and
            // again in the wrap block. This scan is synchronous on the main
            // actor, so at the supported 1,000,000-line scrollback an absent
            // term meant roughly two million line searches before the overlay
            // could say "no match".
            return findFirstBelowViewport(term: term, searchOptions: searchOptions)
        } else if let previousSelection {
            startCol = previousSelection.end.col
            startRow = previousSelection.end.row
        }

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)
        var result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)

        if result == nil {
            let maxRow = terminal.displayBuffer.lines.count
            if startRow + 1 < maxRow {
                for y in (startRow + 1)..<maxRow {
                    searchPosition.startRow = y
                    searchPosition.startCol = 0
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                    if result != nil {
                        break
                    }
                }
            }
        }

        if result == nil && startRow != 0 {
            for y in 0..<startRow {
                searchPosition.startRow = y
                searchPosition.startCol = 0
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                if result != nil {
                    break
                }
            }
        }

        if result == nil, let previousSelection {
            searchPosition.startRow = previousSelection.start.row
            searchPosition.startCol = 0
            result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
        }

        return result
    }

    /// The match nearest the bottom of the visible region, searching upward.
    ///
    /// Used for the first hit of a fresh term, where there is no selection to
    /// resume from. Reverse search within each line so the result is the last
    /// match on the nearest line rather than the first, which is what "nearest
    /// to the viewport" means when a line holds several.
    private func findNearestAtOrAboveViewport(
        term: String,
        searchOptions: SearchOptions?
    ) -> SearchResult? {
        guard let bottom = viewportBottomRow() else { return nil }

        // The line at the viewport edge, read as a WHOLE logical line rather
        // than bounded at the edge itself.
        //
        // A soft-wrapped line straddles that edge, and a reverse search
        // bounded by the viewport column excludes a term that begins on the
        // last visible row and finishes below it. Bounding here and then
        // returning the first match found further up would hand back an older
        // match while a nearer one sat on the boundary line, unexamined — the
        // below-viewport pass never runs, because this one succeeded.
        let boundaryStart = logicalLineStart(of: bottom)
        // The line's ACTUAL extent, not one row past the viewport. A literal
        // longer than a row, or a regex match spanning several, can begin on
        // the last visible row and end well below it; a bound that stopped at
        // `bottom + 1` excluded those, and an older match above then won.
        let boundaryEnd = logicalLineEnd(from: boundaryStart)
        var searchPosition = SearchPosition(
            startCol: terminal.cols * (boundaryEnd - boundaryStart + 1),
            startRow: boundaryStart
        )
        // Spanning the edge is allowed; STARTING past it is not.
        //
        // Reading the line whole is what finds a match that begins on the last
        // visible row and finishes below it. But it also offers any purely
        // offscreen match on that same line, and a reverse search returns the
        // last one — selecting that would scroll away from the visible match
        // this whole path exists to prefer.
        //
        // ONE forward pass, keeping the last candidate that starts at or above
        // the edge. Re-entering the reverse search with a shrinking bound also
        // works and is what this did first, but each re-entry re-materializes
        // the line's matches: quadratic in the number of matches on a single
        // logical line, synchronously on the main actor, which is the hang
        // class this PR already fixed once.
        var result = lastMatchStarting(
            atOrAbove: bottom,
            onLineFrom: boundaryStart,
            term: term,
            searchOptions: searchOptions
        )
        guard result == nil else { return result }
        guard boundaryStart > 0 else { return nil }

        // Set once, then left alone — the same shape as
        // `findPreviousWithSelection`'s reverse loop, and for the same reason.
        // A reverse `findInLine` accumulates into `startCol` as it walks back
        // through a wrapped logical line's continuation rows; re-seeding it to
        // `terminal.cols` on every iteration discards that, so only the first
        // physical row of a wrapped line is ever examined and a nearer match
        // on a continuation row loses to an older unwrapped one.
        searchPosition.startCol = max(searchPosition.startCol, terminal.cols)
        for y in stride(from: boundaryStart - 1, through: 0, by: -1) {
            searchPosition.startRow = y
            result = findInLine(
                term: term,
                searchPosition: &searchPosition,
                searchOptions: searchOptions,
                isReverseSearch: true
            )
            if result != nil { break }
        }
        return result
    }

    /// The bottom row of the visible region, clamped to the buffer, or nil if
    /// the buffer is empty.
    private func viewportBottomRow() -> Int? {
        let lastLine = terminal.displayBuffer.lines.count - 1
        guard lastLine >= 0 else { return nil }
        let bottom = min(terminal.displayBuffer.yDisp + terminal.rows - 1, lastLine)
        return bottom >= 0 ? bottom : nil
    }

    /// The first match strictly below the visible region, scanning downward.
    ///
    /// The other half of a fresh term's search: `findNearestAtOrAboveViewport`
    /// covers 0...bottom, this covers the rest, and between them the buffer is
    /// read once. "Further down the buffer" must never become "no match at
    /// all" just because nothing was on screen.
    private func findFirstBelowViewport(
        term: String,
        searchOptions: SearchOptions?
    ) -> SearchResult? {
        guard let bottom = viewportBottomRow() else { return nil }
        let maxRow = terminal.displayBuffer.lines.count
        guard bottom + 1 < maxRow else { return nil }
        // Start at the LOGICAL line that row `bottom + 1` belongs to, from
        // column 0 — not at the physical row with the accumulated offset
        // `findInLine` would walk back to.
        //
        // A soft-wrapped line straddles the viewport edge, and each half's
        // search is bounded by a column offset. A term that begins on the last
        // visible row and finishes on the first row below it sits past the
        // reverse pass's bound and before the forward pass's, so a strict
        // partition by physical row loses it from both. Re-reading that one
        // logical line in full costs a line and cannot lose a match; the
        // worst case is re-finding something the pass above already rejected,
        // which is a better answer than none.
        let lines = terminal.displayBuffer.lines
        var searchPosition = SearchPosition(startCol: 0, startRow: 0)
        var y = logicalLineStart(of: bottom + 1)
        while y < maxRow {
            searchPosition.startRow = y
            searchPosition.startCol = 0
            if let result = findInLine(
                term: term,
                searchPosition: &searchPosition,
                searchOptions: searchOptions,
                isReverseSearch: false
            ) {
                return result
            }
            // Step to the next LOGICAL line. Stepping one physical row at a
            // time re-enters `findInLine` on each continuation, which walks
            // back to this same logical start and scans the whole line again
            // — O(N^2) synchronous work on the main actor for a line spanning
            // N rows, which long minified output produces routinely.
            var next = y + 1
            while next < maxRow, lines[next].isWrapped { next += 1 }
            y = next
        }
        return nil
    }

    /// The last match on one logical line whose START row is at or above
    /// `limit`, or nil if it has none.
    ///
    /// A single forward walk. Crossing the edge is allowed — the constraint is
    /// on where a match BEGINS — so a term that starts on the last visible row
    /// and finishes below it is kept, while one that begins offscreen is not.
    private func lastMatchStarting(
        atOrAbove limit: Int,
        onLineFrom start: Int,
        term: String,
        searchOptions: SearchOptions?
    ) -> SearchResult? {
        var best: SearchResult?
        var position = SearchPosition(startCol: 0, startRow: start)
        while true {
            guard let candidate = findInLine(
                term: term,
                searchPosition: &position,
                searchOptions: searchOptions,
                isReverseSearch: false
            ) else { break }
            guard candidate.row <= limit else { break }
            best = candidate
            // Past this match's END, not one column past its start.
            //
            // Advancing a single column made the walk consider occurrences
            // that overlap one it had already accepted — matches the ordinary
            // search cycle never produces, since Enter and Cmd+G resume from
            // `previousSelection.end`. It also means the walk steps once per
            // MATCH rather than once per character.
            let consumed = max(candidate.size, 1)
            let offset = (candidate.row - start) * terminal.cols + candidate.col + consumed
            position = SearchPosition(startCol: offset, startRow: start)
        }
        return best
    }

    /// The last physical row of the logical line beginning at `start`.
    private func logicalLineEnd(from start: Int) -> Int {
        let lines = terminal.displayBuffer.lines
        var end = start
        while end + 1 < lines.count, lines[end + 1].isWrapped {
            end += 1
        }
        return end
    }

    /// The first physical row of the logical line `row` belongs to.
    ///
    /// A wrapped row is a continuation; walking up until one is not gives the
    /// row whose cache entry holds the whole logical line.
    private func logicalLineStart(of row: Int) -> Int {
        let lines = terminal.displayBuffer.lines
        var start = row
        while start > 0, start < lines.count, lines[start].isWrapped {
            start -= 1
        }
        return start
    }

    func findPreviousWithSelection (term: String, searchOptions: SearchOptions? = nil, cachedSearchTerm: String?, previousSelection: SearchSelection?) -> SearchResult? {
        if term.isEmpty {
            return nil
        }

        lineCache.initLinesCache()

        let maxRow = terminal.displayBuffer.lines.count - 1
        var startRow = maxRow
        var startCol = terminal.cols
        let isReverseSearch = true

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)
        var result: SearchResult?

        if let previousSelection {
            startRow = previousSelection.start.row
            startCol = previousSelection.start.col
            searchPosition.startRow = startRow
            searchPosition.startCol = startCol
            if cachedSearchTerm != term {
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                if result == nil {
                    startRow = previousSelection.end.row
                    startCol = previousSelection.end.col
                    searchPosition.startRow = startRow
                    searchPosition.startCol = startCol
                }
            }
        }

        if result == nil {
            result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
        }

        if result == nil {
            searchPosition.startCol = max(searchPosition.startCol, terminal.cols)
            if startRow - 1 >= 0 {
                for y in stride(from: startRow - 1, through: 0, by: -1) {
                    searchPosition.startRow = y
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                    if result != nil {
                        break
                    }
                }
            }
        }

        if result == nil && startRow != maxRow {
            for y in stride(from: maxRow, through: startRow, by: -1) {
                searchPosition.startRow = y
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                if result != nil {
                    break
                }
            }
        }

        return result
    }

    private func isWholeWord (searchIndex: Int, line: String, term: String) -> Bool {
        let beforeIndex = searchIndex - 1
        let afterIndex = searchIndex + term.count

        let beforeIsBoundary: Bool
        if beforeIndex < 0 {
            beforeIsBoundary = true
        } else {
            beforeIsBoundary = nonWordCharacters.contains(character(at: beforeIndex, in: line) ?? " ")
        }

        let afterIsBoundary: Bool
        if afterIndex >= line.count {
            afterIsBoundary = true
        } else {
            afterIsBoundary = nonWordCharacters.contains(character(at: afterIndex, in: line) ?? " ")
        }

        return beforeIsBoundary && afterIsBoundary
    }

    private func character (at offset: Int, in line: String) -> Character? {
        guard offset >= 0 && offset < line.count else {
            return nil
        }
        let idx = line.index(line.startIndex, offsetBy: offset)
        return line[idx]
    }

    private func findInLine (term: String, searchPosition: inout SearchPosition, searchOptions: SearchOptions? = nil, isReverseSearch: Bool = false) -> SearchResult? {
        let row = searchPosition.startRow
        let col = searchPosition.startCol
        let buffer = terminal.displayBuffer

        guard row >= 0 && row < buffer.lines.count else {
            return nil
        }

        let firstLine = buffer.lines[row]
        if firstLine.isWrapped {
            if isReverseSearch {
                searchPosition.startCol += terminal.cols
                return nil
            }
            searchPosition.startRow -= 1
            searchPosition.startCol += terminal.cols
            return findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
        }

        var cache = lineCache.getLineFromCache(row: row)
        if cache == nil {
            let translated = lineCache.translateBufferLineToStringWithWrap(lineIndex: row, trimRight: true)
            lineCache.setLineInCache(row: row, entry: translated)
            cache = translated
        }

        guard let cacheEntry = cache else {
            return nil
        }

        let stringLine = cacheEntry.lineAsString
        let offsets = cacheEntry.lineOffsets
        let offset = bufferColsToStringOffset(startRow: row, cols: col)
        let options = searchOptions ?? SearchOptions()

        var resultIndex: Int?
        var matchTerm = term

        // EVERY candidate on the line is considered, not just the first one
        // found. With Whole Word on, a line like `NEEDLE NEEDLEX` offers the
        // trailing partial to a reverse search first; rejecting it used to
        // abandon the whole line, so the valid `NEEDLE` sitting right beside
        // it was never seen and the line reported no match. The same held
        // forward for `NEEDLEX NEEDLE`.
        //
        // Only the word check can reject a candidate, so with Whole Word off
        // the first candidate is always taken and this loops exactly once.
        let accepts: (Int, String) -> Bool = { index, candidate in
            !options.wholeWord || self.isWholeWord(searchIndex: index, line: stringLine, term: candidate)
        }

        if options.regex {
            guard let regex = regex(for: term, caseSensitive: options.caseSensitive) else {
                return nil
            }
            let clampedOffset = min(offset, stringLine.count)
            let offsetIndex = stringLine.index(stringLine.startIndex, offsetBy: clampedOffset)
            if isReverseSearch {
                // Backwards wants the LAST acceptable match, so the range has
                // to be walked in full either way — the same cost the original
                // `matches(in:).last` paid, and bounded by the viewport offset.
                let searchRange = NSRange(stringLine.startIndex..<offsetIndex, in: stringLine)
                for match in regex.matches(
                    in: stringLine,
                    options: Self.subrangeMatching,
                    range: searchRange
                ).reversed() {
                    guard match.range.length > 0, let matchRange = Range(match.range, in: stringLine) else { continue }
                    let index = stringLine.distance(from: stringLine.startIndex, to: matchRange.lowerBound)
                    let candidate = String(stringLine[matchRange])
                    if accepts(index, candidate) {
                        resultIndex = index
                        matchTerm = candidate
                        break
                    }
                }
            } else {
                // Forwards wants the FIRST acceptable match, so it stops at
                // one. Materializing the whole array instead — as an earlier
                // version of this did — makes `findAll`, which re-enters here
                // after every result, quadratic: one soft-wrapped 20,000
                // character line matching `a` took about a second to count,
                // synchronously, on the main actor.
                let searchRange = NSRange(offsetIndex..<stringLine.endIndex, in: stringLine)
                regex.enumerateMatches(
                    in: stringLine,
                    options: Self.subrangeMatching,
                    range: searchRange
                ) { match, _, stop in
                    guard let match, match.range.length > 0,
                          let matchRange = Range(match.range, in: stringLine) else { return }
                    let index = stringLine.distance(from: stringLine.startIndex, to: matchRange.lowerBound)
                    let candidate = String(stringLine[matchRange])
                    guard accepts(index, candidate) else { return }
                    resultIndex = index
                    matchTerm = candidate
                    stop.pointee = true
                }
            }
        } else {
            let searchOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            let clampedOffset = min(offset, stringLine.count)
            let offsetIndex = stringLine.index(stringLine.startIndex, offsetBy: clampedOffset)

            if isReverseSearch {
                if clampedOffset - matchTerm.count >= 0 {
                    var upperBound = offsetIndex
                    while let foundRange = stringLine.range(
                        of: matchTerm,
                        options: searchOptions.union(.backwards),
                        range: stringLine.startIndex..<upperBound
                    ) {
                        let index = stringLine.distance(from: stringLine.startIndex, to: foundRange.lowerBound)
                        if accepts(index, matchTerm) {
                            resultIndex = index
                            break
                        }
                        // Rejected on its word boundary. Continue further back
                        // on this line rather than giving up on it.
                        //
                        // The next bound is just before this match's END, not
                        // its start, because matches can OVERLAP: searching
                        // `--` in `---a` rejects the one at column 1 for its
                        // trailing `a`, and bounding at column 1 would exclude
                        // the valid one at column 0, which ends at column 2.
                        // `.backwards` needs the whole match inside the range,
                        // so the range has to keep room for it.
                        //
                        // Still strictly decreasing — the new bound is below
                        // the old one — so this terminates.
                        guard foundRange.upperBound > stringLine.startIndex else { break }
                        upperBound = stringLine.index(before: foundRange.upperBound)
                    }
                }
            } else {
                var lowerBound = offsetIndex
                while lowerBound < stringLine.endIndex,
                      let foundRange = stringLine.range(
                          of: matchTerm,
                          options: searchOptions,
                          range: lowerBound..<stringLine.endIndex
                      ) {
                    let index = stringLine.distance(from: stringLine.startIndex, to: foundRange.lowerBound)
                    if accepts(index, matchTerm) {
                        resultIndex = index
                        break
                    }
                    guard foundRange.lowerBound < stringLine.endIndex else { break }
                    lowerBound = stringLine.index(after: foundRange.lowerBound)
                }
            }
        }

        guard let foundIndex = resultIndex else {
            return nil
        }

        var startRowOffset = 0
        while startRowOffset < offsets.count - 1 && foundIndex >= offsets[startRowOffset + 1] {
            startRowOffset += 1
        }

        var endRowOffset = startRowOffset
        while endRowOffset < offsets.count - 1 && (foundIndex + matchTerm.count) >= offsets[endRowOffset + 1] {
            endRowOffset += 1
        }

        let startColOffset = foundIndex - offsets[startRowOffset]
        let endColOffset = foundIndex + matchTerm.count - offsets[endRowOffset]
        let startColIndex = stringLengthToBufferSize(row: row + startRowOffset, offset: startColOffset)
        let endColIndex = stringLengthToBufferSize(row: row + endRowOffset, offset: endColOffset)
        let size = endColIndex - startColIndex + terminal.cols * (endRowOffset - startRowOffset)

        return SearchResult(term: matchTerm, col: startColIndex, row: row + startRowOffset, size: size)
    }

    private func stringLengthToBufferSize (row: Int, offset: Int) -> Int {
        let buffer = terminal.displayBuffer
        guard row >= 0 && row < buffer.lines.count else {
            return 0
        }
        if offset == 0 {
            return 0
        }

        let line = buffer.lines[row]
        var adjustedOffset = offset
        var i = 0
        while i < adjustedOffset && i < line.count {
            let cell = line[i]
            if cell.width == 2 {
                let nextIndex = i + 1
                if nextIndex < line.count {
                    let nextCell = line[nextIndex]
                    if nextCell.width == 0 {
                        adjustedOffset += 1
                    }
                }
            }
            i += 1
        }

        return adjustedOffset
    }

    private func bufferColsToStringOffset (startRow: Int, cols: Int) -> Int {
        let buffer = terminal.displayBuffer
        var lineIndex = startRow
        var offset = 0
        var remainingCols = cols

        while remainingCols > 0 && lineIndex < buffer.lines.count {
            let line = buffer.lines[lineIndex]
            let limit = min(remainingCols, terminal.cols)
            if limit > 0 {
                for i in 0..<limit {
                    let cell = line[i]
                    if cell.width > 0 {
                        offset += 1
                    }
                }
            }
            lineIndex += 1
            if lineIndex >= buffer.lines.count {
                break
            }
            let nextLine = buffer.lines[lineIndex]
            if !nextLine.isWrapped {
                break
            }
            remainingCols -= terminal.cols
        }

        return offset
    }
}

private struct SearchPosition {
    var startCol: Int
    var startRow: Int
}
