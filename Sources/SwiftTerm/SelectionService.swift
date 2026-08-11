//
//  SelectionService.swift
//  iOS
//
//  Created by Miguel de Icaza on 3/5/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

/**
 * Tracks the selection state in the terminal, the selection is determined by the `active`
 * property, and if that is true, then the `start` and `end` represents offsets within
 * the terminal's buffer.  They are guaranteed to be ordered.
 */
class SelectionService: CustomDebugStringConvertible {
    var terminal: Terminal
    
    public init (terminal: Terminal)
    {
        self.terminal = terminal
        _active = false
        start = Position(col: 0, row: 0)
        end = Position(col: 0, row: 0)
        pivot = Position(col: 0, row: 0)
        hasSelectionRange = false
        terminal.register(selection: self)
    }

    private func orderedSelectedRows() -> (
        first: Position,
        last: Position,
        top: Int,
        bottom: Int
    ) {
        let (first, last) = Position.compare(start, end) == .before
            ? (start, end)
            : (end, start)
        // Selection ends are exclusive. `(0, row)` contributes no cells from
        // `row` when the range began on an earlier row.
        let bottom = last.col == 0 && last.row > first.row
            ? last.row - 1
            : last.row
        return (first, last, first.row, bottom)
    }

    /**
     * Translates selection anchors when terminal rows move in place.
     *
     * A selection is dropped when any selected row leaves the moved region or
     * when the range crosses the region boundary. In either case, the original
     * text no longer exists as one contiguous selection.
     */
    func adjustForInPlaceScroll(top: Int, bottom: Int, lines: Int)
    {
        guard active, lines != 0 else { return }

        let selected = orderedSelectedRows()
        guard selected.top <= bottom, selected.bottom >= top else { return }
        guard selected.top >= top, selected.bottom <= bottom else {
            selectNone()
            return
        }

        let translatedTop = selected.top - lines
        let translatedBottom = selected.bottom - lines
        guard translatedTop >= top, translatedBottom <= bottom else {
            selectNone()
            return
        }

        func translated(_ position: Position) -> Position {
            let isExclusiveEndBoundary = position == selected.last
                && selected.last.col == 0
                && selected.last.row == selected.bottom + 1
            guard (position.row >= selected.top && position.row <= selected.bottom)
                    || isExclusiveEndBoundary else {
                return position
            }
            let newRow = position.row - lines
            return Position(col: position.col, row: newRow)
        }

        let newStart = translated(start)
        let newEnd = translated(end)

        let newPivot: Position?
        if let pivot, pivot == start || pivot == end {
            newPivot = translated(pivot)
        } else {
            newPivot = pivot
        }

        start = newStart
        end = newEnd
        pivot = newPivot
        terminal.notifySelectionChanged()
    }

    /**
     * Invalidates a selection that overlaps a column-restricted row shift.
     * A row-based range cannot represent only some of its cells moving.
     */
    func invalidateForColumnRestrictedScroll(top: Int, bottom: Int, left: Int, right: Int)
    {
        guard active else { return }

        let selected = orderedSelectedRows()
        let first = selected.first
        let last = selected.last
        guard selected.top <= bottom, selected.bottom >= top else { return }

        if first.row == last.row, last.col <= left || first.col > right {
            return
        }
        selectNone()
    }

    /**
     * Translates a single-row selection when cells move horizontally.
     *
     * Selection ends are exclusive. A selection entirely before or after the
     * changed columns is unaffected. Content wholly inside the surviving
     * source range moves with its cells; a range that crosses the insertion or
     * deletion boundary, or whose cells are evicted, can no longer represent
     * the same contiguous text and is cleared.
     */
    func adjustForInPlaceCellShift(
        top: Int,
        bottom: Int,
        left: Int,
        right: Int,
        columns: Int
    ) {
        guard active, columns != 0, left <= right else { return }

        let selected = orderedSelectedRows()
        let first = selected.first
        let last = selected.last
        guard selected.top <= bottom, selected.bottom >= top else { return }

        // A horizontal mutation on one of several selected rows cannot be
        // represented by translating only the two range endpoints.
        guard first.row == last.row,
              first.row >= top,
              first.row <= bottom else {
            selectNone()
            return
        }

        // `last.col` is exclusive; ending exactly at `left` does not overlap.
        guard last.col > left, first.col <= right else { return }

        let width = right - left + 1
        let distance = min(abs(columns), width)
        let delta: Int
        if columns > 0 {
            let sourceEnd = right - distance + 1
            guard first.col >= left, last.col <= sourceEnd else {
                selectNone()
                return
            }
            delta = distance
        } else {
            let sourceStart = left + distance
            guard first.col >= sourceStart, last.col <= right + 1 else {
                selectNone()
                return
            }
            delta = -distance
        }

        let originalStart = start
        let originalEnd = end
        func translated(_ position: Position) -> Position {
            Position(col: position.col + delta, row: position.row)
        }

        start = translated(originalStart)
        end = translated(originalEnd)
        if let pivot, pivot == originalStart || pivot == originalEnd {
            self.pivot = translated(pivot)
        }
        terminal.notifySelectionChanged()
    }
    
    /**
     * Controls whether the selection is active or not.   Changing the value will invoke the `selectionChanged`
     * method on the terminal's delegate if the state changes.
     */
    var _active: Bool = false
    public var active: Bool {
        get {
            return _active
        }
        set(newValue) {
            if _active != newValue {
                _active = newValue
                terminal.notifySelectionChanged()
            }
            if active == false {
                pivot = nil
            }
        }
    }
    
    // This avoids the user visible cache
    func setActiveAndNotify () {
        _active = true
        terminal.notifySelectionChanged()
    }

    /**
     * Whether any range is selected
     */
    public private(set) var hasSelectionRange: Bool

    /**
     * Returns the selection starting point in buffer coordinates
     */
    public private(set) var start: Position {
        didSet {
          hasSelectionRange = start != end
        }
    }

    /**
     * Used to track the pivot point when selection in iOS-style selection
     */
    public var pivot: Position? 

    /**
     * Returns the selection ending point in buffer coordinates
     */
    public private(set) var end: Position {
        didSet {
          hasSelectionRange = start != end
        }
    }
    
    /// True if the selection spans more than one line
    public var isMultiLine: Bool {
        return start.row != end.row
    }
    
    /**
     * Starts the selection from the specific screen-relative location
     */
    public func startSelection (row: Int, col: Int)
    {
        setSoftStart(row: row, col: col)
        selectionMode = .character
        setActiveAndNotify()
    }
        
    func clamp (_ buffer: Buffer, _ p: Position) -> Position {
        let maxRow = max(0, buffer.lines.count - 1)
        return Position(col: min(p.col, buffer.cols - 1), row: min(p.row, maxRow))
    }
    /**
     * Sets the selection, this is validated against the
     */
    public func setSelection (start: Position, end: Position) {
        let buffer = terminal.displayBuffer
        let sclamped = clamp (buffer, start)
        let eclamped = clamp (buffer, end)
        
        self.start = sclamped
        self.end = eclamped
        
        setActiveAndNotify()
    }
    
    /**
     * Starts selection, the range is determined by the last start position
     */
    public func startSelection ()
    {
        end = start
        selectingRows = false
        selectionMode = .character
        setActiveAndNotify()
    }
    
    /**
     * Sets the start and end positions but does not start selection
     * this lets us record the last position of mouse clicks so that
     * drag and shift+click operations know from where to start selection
     * from.
     *
     * The location is screen-relative
     */
    public func setSoftStart (row: Int, col: Int) {
        setSoftStart (bufferPosition: Position(col: col, row: row + terminal.displayBuffer.yDisp))
    }
    
    /**
     * Sets the start and end positions but does not start selection
     * this lets us record the last position of mouse clicks so that
     * drag and shift+click operations know from where to start selection
     * from.
     *
     * The locoation is buffer-relative
     */
    public func setSoftStart (bufferPosition: Position) {
        start = bufferPosition
        end = bufferPosition
        setActiveAndNotify()
    }
    
    /**
     * Extends the selection based on the user "shift" clicking. This has
     * slightly different semantics than a "drag" extension because we can
     * shift the start to be the last prior end point if the new extension
     * is before the current start point.
     *
     * The row is screen-relative
     */
    public func shiftExtend (row: Int, col: Int)
    {
        var newPos = Position  (col: col, row: row + terminal.displayBuffer.yDisp)
        if selectingRows {
            if Position.compare(start, newPos) == .before {
                newPos.col = terminal.cols - 1
            } else {
                newPos.col = 0
            }
        }
        print("SelectinRows=\(selectingRows)")
        shiftExtend (bufferPosition: newPos)
    }
    
    /**
     * Extends the selection based on the user "shift" clicking. This has
     * slightly different semantics than a "drag" extension because we can
     * shift the start to be the last prior end point if the new extension
     * is before the current start point.
     *
     * The bufferPosition is buffer-relative
     */
    public func shiftExtend (bufferPosition newEnd: Position) {
        var adjustedNewEnd = newEnd
        
        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(newEnd, start) == .before ? -1 : 1
            adjustedNewEnd = extendToWordBoundary(position: newEnd, in: terminal.displayBuffer, direction: direction)
        }
        
        var shouldSwapStart = false
        if Position.compare (start, end) == .before {
            // start is before end, is the new end before Start
            if Position.compare (adjustedNewEnd, start) == .before {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        } else if Position.compare (start, end) == .after {
            if Position.compare (adjustedNewEnd, start) == .after {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        }
        if (shouldSwapStart) {
            start = end
        }
        end = adjustedNewEnd
        
        setActiveAndNotify()
    }
    
    /**
     * Implements the iOS selection around the pivot, that is, the handle that is being dragged
     * becomes the pivot point for start/end
     *
     * The row is screen-relative, for buffer relative use the `pivotExtend(bufferPosition:)` overload
     */
    public func pivotExtend (row: Int, col: Int) {
        let newPoint = Position  (col: col, row: row + terminal.displayBuffer.yDisp)

        return pivotExtend(bufferPosition: newPoint)
    }
    
    /**
     * Implements the iOS selection around the pivot, that is, the handle that is being dragged
     * becomes the pivot point for start/end
     *
     * The position is buffer-relative, for screen relative, use `pivotExtend(row:col:)`
     */
    public func pivotExtend (bufferPosition: Position) {
        guard let pivot = pivot else {
            return
        }
        
        var adjustedPosition = bufferPosition
        
        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(bufferPosition, pivot) == .before ? -1 : 1
            adjustedPosition = extendToWordBoundary(position: bufferPosition, in: terminal.displayBuffer, direction: direction)
        }
        
        switch Position.compare (adjustedPosition, pivot) {
        case .after:
            start = pivot
            end = adjustedPosition
        case .before:
            start = adjustedPosition
            end = pivot
        case .equal:
            start = pivot
            end = pivot
        }
        
        setActiveAndNotify()
    }
    
    /**
     * Extends the selection by moving the end point to the new point.
     * The row is in screen coordinates
     */
    public func dragExtend (row: Int, col: Int)
    {
        dragExtend(bufferPosition: Position(col: col, row: row + terminal.displayBuffer.yDisp))
    }
    
    /**
     * Extends the selection by moving the end point to the new point.
     * The position is in buffer coordinates
     */
    public func dragExtend (bufferPosition: Position) {
        var adjustedEnd = bufferPosition
        
        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(bufferPosition, start) == .before ? -1 : 1
            adjustedEnd = extendToWordBoundary(position: bufferPosition, in: terminal.displayBuffer, direction: direction)
        }
        
        end = adjustedEnd
        setActiveAndNotify()
    }
    
    /**
     * Selects the entire buffer and triggers the selection
     */
    public func selectAll ()
    {
        start = Position(col: 0, row: 0)
        end = Position(col: terminal.cols-1, row: terminal.displayBuffer.lines.maxLength - 1)
        setActiveAndNotify()
    }
    
    public var selectingRows: Bool = false
    
    /// Tracks the current selection mode to maintain consistency during extension
    public enum SelectionMode {
        case character
        case word
        case row
    }
    
    public var selectionMode: SelectionMode = .character
    
    /**
     * Selectss the specified row and triggers the selection
     */
    public func select(row: Int)
    {
        start = Position(col: 0, row: row)
        end = Position(col: terminal.cols-1, row: row)
        selectingRows = true
        selectionMode = .row
        setActiveAndNotify()
    }

    private func character (at position: Position, in buffer: Buffer) -> Character
    {
        let cell = buffer.getChar (atBufferRelative: position)
        return terminal.getCharacter (for: cell)
    }

    /**
     * Performs a simple "word" selection based on a function that determines inclussion into the group
     */
    func simpleScanSelection (from position: Position, in buffer: Buffer, includeFunc: (Character)-> Bool)
    {
        // Look backward
        var colScan = position.col
        var left = colScan
        while colScan >= 0 {
            let ch = character (at: Position (col: colScan, row: position.row), in: buffer)
            if !includeFunc (ch) {
                break
            }
            left = colScan
            colScan -= 1
        }
        
        // Look forward
        colScan = position.col
        var right = colScan
        let limit = terminal.cols
        while colScan < limit {
            let ch = character (at: Position (col: colScan, row: position.row), in: buffer)
            if !includeFunc (ch) {
                break
            }
            colScan += 1
            right = colScan
        }
        start = Position (col: left, row: position.row)
        end = Position(col: right, row: position.row)
    }
    
    /**
     * Performs a forward search for the `end` character, but this can extend across matching subexpressions
     * made of pais of parenthesis, braces and brackets.
     */
    func balancedSearchForward (from position: Position, in buffer: Buffer)
    {
        var startCol = position.col
        var wait: [Character] = []
        
        start = position
        
        let maxRow = buffer.rows + buffer.yDisp
        if position.row >= maxRow {
            return
        }
        for line in position.row..<maxRow {
            for col in startCol..<terminal.cols {
                let p =  Position(col: col, row: line)
                let ch = character (at: p, in: buffer)
                
                if ch == "(" {
                    wait.append (")")
                } else if ch == "[" {
                    wait.append ("]")
                } else if ch == "{" {
                    wait.append ("}")
                } else if let v = wait.last {
                    if v == ch {
                        wait.removeLast()
                        if wait.count == 0 {
                            end = Position(col: p.col+1, row: p.row)
                            return
                        }
                    }
                }
            }
            startCol = 0
        }
        start = position
        end = position
    }

    /**
     * Performs a forward search for the `end` character, but this can extend across matching subexpressions
     * made of pais of parenthesis, braces and brackets.
     */
    func balancedSearchBackward (from position: Position, in buffer: Buffer)
    {
        var startCol = position.col
        var wait: [Character] = []

        end = position
        
        for line in (0...position.row).reversed() {
            for col in (0...startCol).reversed() {
                let p =  Position(col: col, row: line)
                let ch = character (at: p, in: buffer)
                
                if ch == ")" {
                    wait.append ("(")
                } else if ch == "]" {
                    wait.append ("[")
                } else if ch == "}" {
                    wait.append ("{")
                } else if let v = wait.last {
                    if v == ch {
                        wait.removeLast()
                        if wait.count == 0 {
                            end = Position(col: end.col+1, row: end.row)
                            start = p
                            return
                        }
                    }
                }
            }
            startCol = terminal.cols-1
        }
        start = position
        end = position
    }

    let nullChar = Character(UnicodeScalar(0))
    
    /**
     * Extends a position to the nearest word boundary based on the character at that position
     */
    func extendToWordBoundary(position: Position, in buffer: Buffer, direction: Int) -> Position {
        let ch = character (at: position, in: buffer)
        var includeFunc: (Character) -> Bool
        
        switch ch {
        case Character(UnicodeScalar(0)):
            includeFunc = { ch in ch == Character(UnicodeScalar(0)) }
        case " ":
            includeFunc = { ch in ch == " " }
        case let ch where ch.isLetter || ch.isNumber:
            includeFunc = { ch in ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" }
        default:
            return position
        }
        
        var result = position
        if direction < 0 {
            // Extend backward
            var col = position.col
            while col >= 0 {
                let testCh = character (at: Position(col: col, row: position.row), in: buffer)
                if !includeFunc(testCh) {
                    break
                }
                result.col = col
                col -= 1
            }
        } else {
            // Extend forward
            var col = position.col
            while col < terminal.cols {
                let testCh = character (at: Position(col: col, row: position.row), in: buffer)
                if !includeFunc(testCh) {
                    break
                }
                col += 1
                result.col = col
            }
        }
        
        return result
    }
    /**
     * Implements the behavior to select the word at the specified position or an expression
     * which is a balanced set parenthesis, braces or brackets
     */
    public func selectWordOrExpression (at uncheckedPosition: Position, in buffer: Buffer)
    {
//        let position = Position(
//            col: max (min (uncheckedPosition.col, buffer.cols-1), 0),
//            row: max (min (uncheckedPosition.row, buffer.rows-1+buffer.yDisp), buffer.yDisp))
        let position = Position (col: (min (terminal.cols, max (uncheckedPosition.col, 0))),
                                 row: (max (uncheckedPosition.row, 0)))
        switch character (at: position, in: buffer) {
        case Character(UnicodeScalar(0)):
            simpleScanSelection (from: position, in: buffer) { ch in ch == nullChar }
        case " ":
            // Select all white space
            simpleScanSelection (from: position, in: buffer) { ch in ch == " " }
        case let ch where ch.isLetter || ch.isNumber:
            simpleScanSelection (from: position, in: buffer) { ch in ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" }
        case "{":
            fallthrough
        case "(":
            fallthrough
        case "[":
            balancedSearchForward (from: position, in: buffer)
        case ")":
            fallthrough
        case "]":
            fallthrough
        case "}":
            balancedSearchBackward(from: position, in: buffer)
        default:
            // For other characters, we just stop there
            start = position
            end = position
        }
        selectionMode = .word
        setActiveAndNotify()
    }
    
    /**
     * Clears the selection
     */
    public func selectNone ()
    {
        if active {
            active = false
            selectionMode = .character
        }
    }
    
    public func getSelectedText () -> String {
        let (min, max) = if Position.compare(start, end) == .before {
            (start, end)
        } else {
            (end, start)
        }
        let r = terminal.getDisplayText(start: min, end: max)
        return r
    }
    
    public var debugDescription: String {
        return "[Selection (active=\(active), start=\(start) end=\(end) hasSR=\(hasSelectionRange) pivot=\(pivot?.debugDescription ?? "nil")]"
    }
}
