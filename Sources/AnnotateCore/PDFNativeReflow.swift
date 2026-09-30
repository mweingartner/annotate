import CoreGraphics
import Foundation

/// Minimal reflow after an edit: when an edited paragraph gains or loses lines, the
/// content below it in the same column moves by exactly that height, as far as the
/// first gap that absorbs the change, so everything else stays where it was. Moved
/// content is only translated, never re-set, so it keeps its exact look.
///
/// Content is moved in units that can be translated without changing anything else:
/// a text object (its text matrix is offset), an image or form (drawn inside a local
/// translation), or a painted path. When a unit that has to move can't be moved safely,
/// nothing moves and the reason is reported.
public struct PDFNativeReflowRequest: Equatable, Sendable {
    /// How much taller the edited block became (negative when it became shorter), in points.
    public let delta: Double
    /// The edited paragraph's original block, in page space.
    public let block: CGRect
    /// The smallest gap that may remain between moved content and what follows it:
    /// a line of the paragraph, so sections never run together.
    public let minimumGap: Double

    public init(delta: Double, block: CGRect, minimumGap: Double) {
        self.delta = delta; self.block = block; self.minimumGap = minimumGap
    }
}

/// Why the content below an edit could not move; the edit is left as it was.
public struct PDFNativeReflowRefusal: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// What moved, for moving the page's annotations with it.
public struct PDFNativeReflowResult: Equatable, Sendable {
    /// The region, in the original page space, whose content moved.
    public let region: CGRect
    /// How far it moved vertically (negative is down the page).
    public let offset: Double
}

enum PDFNativeReflow {
    enum Kind: Equatable {
        /// A text object from `BT` to `ET`, with the indexes of its `Tm` operators.
        case text(begin: Int, end: Int, matrices: [Int])
        /// Operations drawn inside a local translation: a painted path, image or form.
        case wrapped(first: Int, last: Int)
        /// Drawing that cannot be moved (shadings, clipping text).
        case fixed
    }

    struct Unit {
        let kind: Kind
        /// Page-space bounds of what the unit draws.
        let bounds: CGRect
        /// The transformation in force when the unit starts (user space to page space).
        let ctm: CGAffineTransform
        /// The clip in force, as page-space bounds; nil when nothing clips.
        let clip: CGRect?
        /// Whether the unit draws any of the glyphs being edited.
        let edited: Bool
    }

    /// The page's top-level drawing, in drawing order.
    static func units(of program: PDFNativeTextProgram) throws -> [Unit] {
        struct State { var ctm = CGAffineTransform.identity; var clip: CGRect?; var lineWidth = 1.0 }
        var state = State(), stack: [State] = []
        var units: [Unit] = []
        var textStart: Int?, textMatrices: [Int] = [], textBounds = CGRect.null, textEdited = false, textClips = false
        var pathStart: Int?, pathBounds = CGRect.null, pendingClip = false
        var current = CGPoint.zero
        func point(_ operands: [PDFNativeToken], _ offset: Int) -> CGPoint? {
            guard operands.count >= offset + 2, let x = operands[offset].number, let y = operands[offset + 1].number else { return nil }
            return CGPoint(x: x, y: y).applying(state.ctm)
        }
        func add(_ page: CGPoint) { pathBounds = pathBounds.union(CGRect(origin: page, size: .zero)) }
        for (index, operation) in program.operations.enumerated() {
            let operands = operation.operands
            // Only path construction may interrupt a path, and nothing that changes the
            // coordinate system or draws outside text may interrupt a text object; content
            // written otherwise can't be wrapped or offset as a unit, so the page stays put.
            if pathStart != nil, !Self.pathOperators.contains(operation.name) { throw Refusal.fixedContent }
            if textStart != nil, Self.outsideText.contains(operation.name) { throw Refusal.fixedContent }
            switch operation.name {
            case "q": stack.append(state)
            case "Q": state = stack.popLast() ?? state
            case "cm":
                // Exactly six numbers; renderers read stray operands differently, so such a
                // page's content stays put.
                let values = operands.compactMap(\.number)
                guard operands.count == 6, values.count == 6 else { throw Refusal.fixedContent }
                state.ctm = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(state.ctm)
            case "w": state.lineWidth = operands.first?.number ?? state.lineWidth
            case "BT": textStart = index; textMatrices = []; textBounds = .null; textEdited = false; textClips = false
            case "Tm": if textStart != nil { textMatrices.append(index) }
            case "ET":
                guard let start = textStart else { continue }
                let kind: Kind = textClips ? .fixed : .text(begin: start, end: index, matrices: textMatrices)
                if !textBounds.isNull { units.append(Unit(kind: kind, bounds: textBounds, ctm: state.ctm, clip: state.clip, edited: textEdited)) }
                // Clipping text bounds all later drawing at this level, like a clipping path.
                if textClips { state.clip = state.clip.map { $0.intersection(textBounds) } ?? textBounds }
                textStart = nil
            case "Tj", "TJ", "'", "\"":
                for case .glyph(let glyph) in program.shows[index] ?? [] {
                    textBounds = textBounds.union(glyph.bounds)
                    if glyph.selected { textEdited = true }
                    if glyph.clipping { textClips = true }
                }
            case "m", "l":
                if pathStart == nil { pathStart = index; pathBounds = .null }
                if let page = point(operands, 0) { add(page); current = page }
            case "c":
                for offset in [0, 2, 4] { if let page = point(operands, offset) { add(page) } }
            case "v", "y":
                for offset in [0, 2] { if let page = point(operands, offset) { add(page) } }
            case "re":
                if pathStart == nil { pathStart = index; pathBounds = .null }
                let values = operands.compactMap(\.number)
                if values.count == 4 {
                    let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]).applying(state.ctm)
                    pathBounds = pathBounds.union(rect)
                }
            case "h": _ = current
            case "W", "W*": pendingClip = true
            case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
                guard let start = pathStart else { pendingClip = false; continue }
                if pendingClip {
                    // A clip bounds all later drawing at this level; it never moves itself.
                    state.clip = state.clip.map { $0.intersection(pathBounds) } ?? pathBounds
                }
                if operation.name != "n" {
                    // Strokes reach half a line width beyond the path.
                    let scale = hypot(state.ctm.a, state.ctm.b)
                    let stroked = ["S", "s", "B", "B*", "b", "b*"].contains(operation.name)
                    let bounds = stroked ? pathBounds.insetBy(dx: -state.lineWidth * scale / 2, dy: -state.lineWidth * scale / 2) : pathBounds
                    if !pendingClip {
                        units.append(Unit(kind: .wrapped(first: start, last: index), bounds: bounds, ctm: state.ctm, clip: state.clip, edited: false))
                    } else {
                        units.append(Unit(kind: .fixed, bounds: bounds, ctm: state.ctm, clip: state.clip, edited: false))
                    }
                }
                pathStart = nil; pendingClip = false
            case "Do":
                if let image = program.images[index] {
                    units.append(Unit(kind: .wrapped(first: index, last: index), bounds: image.bounds, ctm: state.ctm, clip: state.clip, edited: false))
                } else if let form = program.forms[index] {
                    let drawn = form.glyphs.reduce(CGRect.null) { $0.union($1.bounds) }
                        .union(form.allImages.reduce(CGRect.null) { $0.union($1.bounds) })
                    let edited = form.glyphs.contains(where: \.selected)
                    // Paths inside forms are not measured; the form's own box bounds them. A form
                    // that draws only text and images (as edited text does, in a page-sized
                    // form) is bounded by what it draws.
                    let box = program.formBounds[index] ?? .null
                    let bounds = drawn.isNull || Self.paints(form) ? drawn.union(box) : drawn
                    units.append(Unit(kind: edited ? .fixed : .wrapped(first: index, last: index),
                                      bounds: bounds.isNull ? (state.clip ?? .infinite) : bounds, ctm: state.ctm, clip: state.clip, edited: edited))
                }
            case "sh":
                units.append(Unit(kind: .fixed, bounds: state.clip ?? .infinite, ctm: state.ctm, clip: state.clip, edited: false))
            default: break
            }
        }
        return units
    }

    /// Operators that may appear between a path's first point and the operator that paints it.
    static let pathOperators: Set<String> = ["m", "l", "c", "v", "y", "h", "re", "W", "W*",
                                             "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"]
    /// Operators that never belong between BT and ET.
    static let outsideText: Set<String> = pathOperators.union(["q", "Q", "cm", "Do", "sh", "BI"])

    /// Whether a form paints paths or shadings (drawing its glyphs and images don't measure),
    /// itself or in a form it draws.
    static func paints(_ form: PDFNativeTextProgram) -> Bool {
        form.operations.contains { ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "sh"].contains($0.name) }
            || form.forms.values.contains(where: paints)
    }

    enum Refusal: Error, Equatable {
        case edgeOfPage, straddles, fixedContent, clipped, noRoom
        var message: String {
            switch self {
            case .edgeOfPage: "The text needs more room, and the content below it can't move further down the page."
            case .straddles: "The text needs more room, but the content below it is drawn together with the paragraph, so it can't move on its own."
            case .fixedContent: "The text needs more room, but the content below it includes artwork that can't be moved safely."
            case .clipped: "The text needs more room, but moving the content below it would cut it off at a clipping edge."
            case .noRoom: "The text needs more room than the page has below it."
            }
        }
    }

    /// Which units move, and how far, to make `request.delta` more room below the block.
    static func plan(_ request: PDFNativeReflowRequest, units: [Unit], page: CGRect) throws -> (moving: [Int], offset: Double, region: CGRect) {
        let block = request.block, delta = request.delta
        guard delta.isFinite, abs(delta) > 0.01, abs(delta) < page.height,
              request.minimumGap.isFinite, request.minimumGap >= 0 else { return ([], 0, .null) }
        let column = block.minX...block.maxX
        func inColumn(_ rect: CGRect) -> Bool { rect.maxX > column.lowerBound + 0.5 && rect.minX < column.upperBound - 0.5 }
        let floor = block.minY - 0.5
        // The edited paragraph's own text must end with the block.
        for unit in units where unit.edited && unit.bounds.minY < floor - 1 { throw Refusal.straddles }
        var below: [Int] = []
        for (index, unit) in units.enumerated() where !unit.edited && inColumn(unit.bounds) && !unit.bounds.isInfinite {
            if unit.bounds.maxY <= floor + 1 { below.append(index) }
            else if unit.bounds.minY < floor - 1, unit.bounds.width < page.width * 0.9 {
                // Drawing that starts above the block's bottom edge and continues below it
                // would tear if part of it moved. A page-wide background or frame stays put.
                throw Refusal.straddles
            }
        }
        // Rows of content, top down: units whose vertical extents overlap form one row.
        let sorted = below.sorted { units[$0].bounds.maxY > units[$1].bounds.maxY }
        var rows: [(top: Double, bottom: Double, members: [Int])] = []
        for index in sorted {
            let bounds = units[index].bounds
            if let last = rows.last, bounds.maxY > last.bottom + 0.01 {
                // In place: copying the members on every merge is quadratic in one tall row.
                rows[rows.count - 1].bottom = min(last.bottom, bounds.minY)
                rows[rows.count - 1].members.append(index)
            } else {
                rows.append((bounds.maxY, bounds.minY, [index]))
            }
        }
        // Move rows down (or up) until a gap wide enough to absorb the change.
        let amount = abs(delta)
        let margin = page.minY + max(18, request.minimumGap)
        var moving: [Int] = [], region = CGRect.null
        for (position, row) in rows.enumerated() {
            moving += row.members
            for member in row.members { region = region.union(units[member].bounds) }
            let nextTop = position + 1 < rows.count ? rows[position + 1].top : margin
            let gap = row.bottom - nextTop
            if gap >= amount + request.minimumGap || (delta < 0 && position + 1 == rows.count) { break }
            if position + 1 == rows.count, delta > 0 { throw Refusal.edgeOfPage }
        }
        // With nothing below, the block itself must still end above the margin.
        if rows.isEmpty, delta > 0, block.minY - delta < margin { throw Refusal.noRoom }
        let offset = -delta
        for index in moving {
            let unit = units[index]
            if unit.kind == .fixed { throw Refusal.fixedContent }
            if let clip = unit.clip, !clip.insetBy(dx: -0.5, dy: -0.5).contains(unit.bounds.offsetBy(dx: 0, dy: offset)) {
                throw Refusal.clipped
            }
        }
        return (moving, offset, region)
    }

    /// Operator replacements that translate `units` by `offset` points vertically.
    static func replacements(moving: [Int], units: [Unit], offset: Double, operations: [PDFNativeOperation],
                             source: [UInt8]) throws -> [Int: String] {
        var replacements: [Int: String] = [:]
        // Operators are copied byte for byte; anything but ASCII (a raw-byte name, say) would
        // not survive as a String, so that content stays put.
        func text(_ index: Int) throws -> String {
            let bytes = source[operations[index].range]
            guard bytes.allSatisfy({ $0 < 0x80 }) else { throw Refusal.fixedContent }
            return String(decoding: bytes, as: UTF8.self)
        }
        func finite(_ values: [Double]) throws {
            guard values.allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { throw Refusal.fixedContent }
        }
        for index in moving {
            let unit = units[index]
            // The page-space move, expressed in the unit's own user space.
            let linear = CGAffineTransform(a: unit.ctm.a, b: unit.ctm.b, c: unit.ctm.c, d: unit.ctm.d, tx: 0, ty: 0)
            let determinant = linear.a * linear.d - linear.b * linear.c
            guard determinant.isFinite, abs(determinant) > 1e-9 else { throw Refusal.fixedContent }
            let move = CGPoint(x: 0, y: offset).applying(linear.inverted())
            try finite([move.x, move.y])
            let dx = nativePDFNumber(move.x), dy = nativePDFNumber(move.y)
            switch unit.kind {
            case .text(let begin, _, let matrices):
                // The text matrix starts at identity after BT; offsetting it moves every line
                // placed relative to it, and absolute Tm placements are offset too.
                replacements[begin] = try text(begin) + "\n1 0 0 1 \(dx) \(dy) Tm"
                for matrix in matrices {
                    let values = operations[matrix].operands.compactMap(\.number)
                    guard operations[matrix].operands.count == 6, values.count == 6 else { throw Refusal.fixedContent }
                    let moved = [values[0], values[1], values[2], values[3], values[4] + move.x, values[5] + move.y]
                    try finite(moved)
                    replacements[matrix] = moved.map(nativePDFNumber).joined(separator: " ") + " Tm"
                }
            case .wrapped(let first, let last):
                replacements[first] = "q 1 0 0 1 \(dx) \(dy) cm\n" + (try replacements[first] ?? text(first))
                replacements[last] = (try replacements[last] ?? text(last)) + "\nQ"
            case .fixed:
                throw Refusal.fixedContent
            }
        }
        return replacements
    }
}
