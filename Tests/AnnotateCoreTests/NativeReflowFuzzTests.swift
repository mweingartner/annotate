import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import AnnotateCore

/// SplitMix64: every generated page replays from its seed.
private struct ReflowRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 ^ 0xD1B5_4A32_D192_ED03 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A hand-built one-page PDF whose resources every generated content stream can use: a
/// standard font `/F1`, an image `/Im`, a form `/Fm` (a filled box with a word) and an
/// axial shading `/Sh`.
enum ReflowPDF {
    static let formContent = "0.8 g 0 0 60 30 re f 0 g BT /F1 8 Tf 4 10 Td (Form) Tj ET"

    static func data(content: String, rotation: Int = 0, xobjects: String = "") -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotation) /Resources << /Font << /F1 4 0 R >> /XObject << /Im 6 0 R /Fm 7 0 R\(xobjects) >> /Shading << /Sh 8 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 9 >>\nstream\n00FF00FF>\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 60 30] /Resources << /Font << /F1 4 0 R >> >> /Length \(formContent.utf8.count) >>\nstream\n\(formContent)\nendstream",
            "<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >>",
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    static func document(content: String, rotation: Int = 0) throws -> PDFDocument {
        try #require(PDFDocument(data: data(content: content, rotation: rotation)))
    }
}

/// The parsed fixture's resources, kept alive with the document that owns them.
@MainActor
private final class ReflowResources {
    let document: CGPDFDocument
    let resources: CGPDFDictionaryRef?
    init() throws {
        let provider = try #require(CGDataProvider(data: ReflowPDF.data(content: "") as CFData))
        document = try #require(CGPDFDocument(provider))
        let page = try #require(document.page(at: 1)?.dictionary)
        resources = PDFNativeTextEditor.inheritedResources(page)
    }
    func program(_ content: String) throws -> PDFNativeTextProgram {
        try PDFNativeTextProgram(data: Data(content.utf8), resources: resources)
    }
}

/// Builds content streams from pieces a real page contains, placed at random. Legal pages
/// follow the content-stream grammar; hostile ones add junk operands and broken nesting.
private struct ReflowComposer {
    var random: ReflowRandom
    let hostile: Bool

    private mutating func pick<T>(_ values: [T]) -> T { values[Int.random(in: 0..<values.count, using: &random)] }
    private mutating func chance(_ odds: Double) -> Bool { Double.random(in: 0..<1, using: &random) < odds }
    /// Coordinates on a quarter-point grid, so translated pages compare exactly.
    private mutating func n(_ range: ClosedRange<Double>) -> String { nativePDFNumber((Double.random(in: range, using: &random) * 4).rounded() / 4) }
    private mutating func words() -> String {
        (0..<Int.random(in: 1...4, using: &random)).map { _ in pick(["Lorem", "ipsum", "dolor", "sit", "amet", "Reflow", "moves", "text"]) }.joined(separator: " ")
    }

    private mutating func matrix() -> String {
        var choices = [
            "1 0 0 1 \(n(-40...40)) \(n(-40...40))",
            "\(n(0.5...2)) 0 0 \(n(0.5...2)) \(n(0...200)) \(n(0...300))",
            "0 1 -1 0 \(n(300...600)) \(n(0...300))",
            "1 0 0 -1 0 \(n(700...792))",
            "1 0 0.25 1 0 0",
        ]
        if hostile {
            choices += ["0 0 0 0 \(n(72...400)) \(n(40...600))", "1e30 0 0 1e30 0 0", "1e-12 0 0 1e-12 300 300",
                        "1 0 0 1 1e300 -1e300", "0 0 0 0 0 0", "1e200 0 0 1e200 0 0", "1e-6 0 0 1e-6 100 100"]
        }
        return pick(choices)
    }

    private mutating func text() -> String {
        let (x, y, size) = (n(60...420), n(30...760), n(6...18))
        switch Int.random(in: 0..<5, using: &random) {
        case 0: return "BT /F1 \(size) Tf \(x) \(y) Td (\(words())) Tj ET"
        case 1: return "BT /F1 10 Tf 12 TL 1 0 0 1 \(x) \(y) Tm (\(words())) Tj T* (\(words())) Tj (\(words())) ' ET"
        case 2: return "BT /F1 \(size) Tf \(x) \(y) Td [(\(words())) -250 (\(words()))] TJ ET"
        case 3: return "BT /F1 9 Tf 1 0 0 1 \(x) \(y) Tm (\(words())) Tj 1 0 0 1 \(n(60...420)) \(n(30...760)) Tm (\(words())) Tj ET"
        default: return "BT /F1 \(size) Tf \(size) 0 0 \(size) \(x) \(y) Tm 0 Tc 2 0 Td (\(words())) Tj 0 -1.2 TD (\(words())) Tj 1 2 (\(words())) \" ET"
        }
    }

    mutating func element(depth: Int) -> String {
        let (x, y) = (n(40...480), n(20...770))
        switch Int.random(in: 0..<18, using: &random) {
        case 0...4: return text()
        case 5: return "\(x) \(y) \(n(1...300)) \(n(0.5...60)) re f"
        case 6: return "\(n(0.25...6)) w \(x) \(y) m \(n(40...480)) \(n(20...770)) l S"
        case 7: return "\(x) \(y) m \(n(40...480)) \(n(20...770)) \(n(40...480)) \(n(20...770)) \(n(40...480)) \(n(20...770)) c h B"
        case 8: return "q \(n(4...120)) 0 0 \(n(4...120)) \(x) \(y) cm /Im Do Q"
        case 9: return "q 1 0 0 1 \(x) \(y) cm /Fm Do Q"
        case 10 where depth < 4:
            let children = (0..<Int.random(in: 1...3, using: &random)).map { _ in element(depth: depth + 1) }
            return "q \(x) \(y) \(n(20...400)) \(n(20...300)) re W n\n" + children.joined(separator: "\n") + "\nQ"
        case 11 where depth < 4:
            let children = (0..<Int.random(in: 1...3, using: &random)).map { _ in element(depth: depth + 1) }
            return "q \(matrix()) cm\n" + children.joined(separator: "\n") + "\nQ"
        case 12: return "q \(x) \(y) \(n(20...300)) \(n(10...80)) re W n /Sh sh Q"
        case 13: return "BT \(pick(["7", "4", "3"])) Tr /F1 12 Tf \(x) \(y) Td (\(words())) Tj ET"
        case 14: return "/Missing Do"
        case 15:
            let levels = Int.random(in: 1...60, using: &random)
            return String(repeating: "q ", count: levels) + element(depth: 4) + String(repeating: " Q", count: levels)
        case 16: return chance(0.5) ? "q /Sh sh Q" : "\(x) \(y) \(n(1...40)) \(n(1...40)) re W n"
        default: return text()
        }
    }

    /// Junk a hostile page mixes in: non-finite and huge operands, broken nesting,
    /// singular and oversized transformations, extra operands, stray painting.
    private mutating func junk() -> String {
        pick(["nan", "inf", "-inf", "1e400 0 0 1 0 0 cm", "1e308 1e308 m 1 1 l S", "-1e308 -1e308 m 1e308 1e308 l S",
              "Q", "q", "BT", "ET", "0 0 0 0 0 0 cm", "1 0 0 1 0 0 7 cm", "1e308 w 100 100 m 200 100 l S",
              "/Nope sh", "/Nope Do", "S", "W n", "1 2 re f", "0 0 1e300 1e300 re f", "BT /F1 12 Tf 1e300 1e300 Td (x) Tj ET",
              "BT /F1 12 Tf 0 0 0 0 100 100 Tm (flat) Tj ET", "(unterminated", "[1 2", "<zz> Tj", "5 Tr", "12 Tr",
              "BT BT ET ET", "1 0 0 1 72 300 cm", "-0 -0 m -0 -0 l S"])
    }

    mutating func page() -> String {
        var parts: [String] = []
        for _ in 0..<Int.random(in: 3...24, using: &random) {
            parts.append(element(depth: 0))
            if hostile, chance(0.3) { parts.append(junk()) }
        }
        return parts.joined(separator: "\n")
    }
}

@Suite("Minimal reflow under fuzzed and hostile content", .serialized)
@MainActor
struct NativeReflowFuzzTests {
    private let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// Marks one text object's glyphs as the ones being edited and returns the paragraph's
    /// block, or chooses a block with nothing edited.
    private func chooseEdit(in program: PDFNativeTextProgram, random: inout ReflowRandom) throws -> CGRect {
        let units = try PDFNativeReflow.units(of: program)
        let texts = units.compactMap { unit -> (Int, Int, CGRect)? in
            if case .text(let begin, let end, _) = unit.kind { return (begin, end, unit.bounds) }
            return nil
        }
        if texts.isEmpty || Int.random(in: 0..<5, using: &random) == 0 {
            let top = Double(Int.random(in: 80...760, using: &random))
            return CGRect(x: 72, y: top - 30, width: 400, height: 30)
        }
        let (begin, end, bounds) = texts[Int.random(in: 0..<texts.count, using: &random)]
        for index in begin...end {
            for case .glyph(let glyph) in program.shows[index] ?? [] { glyph.selected = true }
        }
        return Bool.random(using: &random) ? bounds : CGRect(x: 72, y: bounds.minY, width: 400, height: bounds.height)
    }

    private func request(_ block: CGRect, random: inout ReflowRandom) -> PDFNativeReflowRequest {
        let deltas: [Double] = [7, 14, 28, 60, 250, -7, -14, -28, -60, 0.3, 0, 900, -900]
        let delta = Bool.random(using: &random) ? deltas[Int.random(in: 0..<deltas.count, using: &random)] : Double.random(in: -80...80, using: &random)
        let gaps: [Double] = [0, 6, 14, 30]
        return PDFNativeReflowRequest(delta: delta, block: block, minimumGap: gaps[Int.random(in: 0..<gaps.count, using: &random)])
    }

    private func inColumn(_ rect: CGRect, _ block: CGRect) -> Bool { rect.maxX > block.minX + 0.5 && rect.minX < block.maxX - 0.5 }

    /// Properties every plan must have, whatever the page.
    private func checkPlan(_ plan: (moving: [Int], offset: Double, region: CGRect), request: PDFNativeReflowRequest,
                           units: [PDFNativeReflow.Unit], context: String) {
        let block = request.block
        #expect(Set(plan.moving).count == plan.moving.count, "no unit moves twice: \(context)")
        guard !plan.moving.isEmpty else { #expect(plan.region.isNull, "nothing moved, so no region: \(context)"); return }
        #expect(plan.offset == -request.delta, "\(context)")
        var region = CGRect.null
        for index in plan.moving {
            guard units.indices.contains(index) else { Issue.record("index out of range: \(context)"); return }
            let unit = units[index]
            region = region.union(unit.bounds)
            #expect(!unit.edited, "edited text never moves: \(context)")
            #expect(unit.kind != .fixed, "fixed drawing never moves: \(context)")
            #expect(unit.bounds.maxY <= block.minY + 0.5 + 1e-9, "moved units lie below the block: \(unit.bounds) vs \(block) \(context)")
            #expect(inColumn(unit.bounds, block), "moved units lie in the block's column: \(context)")
            if let clip = unit.clip {
                #expect(clip.insetBy(dx: -0.5, dy: -0.5).contains(unit.bounds.offsetBy(dx: 0, dy: plan.offset)), "moved units stay inside their clip: \(context)")
            }
        }
        #expect(plan.region == region, "the region is exactly what moved: \(context)")
        // What stays below keeps at least the minimum gap from what moved onto it.
        let moving = Set(plan.moving), amount = abs(request.delta)
        for (index, unit) in units.enumerated() where !moving.contains(index) && !unit.edited && !unit.bounds.isInfinite
            && inColumn(unit.bounds, block) && unit.bounds.maxY <= block.minY - 0.5 + 1 {
            #expect(unit.bounds.maxY <= region.minY - amount - request.minimumGap + 0.02,
                    "unmoved content below keeps its gap: \(unit.bounds) vs region \(region), \(context)")
        }
    }

    /// Plans, rewrites and re-reads a page, checking the rewritten stream is sound.
    /// Returns the plan and replacements, or nil when the page was refused or unreadable.
    @discardableResult
    private func exercise(_ content: String, seed: UInt64, legal: Bool) throws -> (moving: [Int], offset: Double, replacements: [Int: String])? {
        let fixture = try ReflowResources()
        var random = ReflowRandom(seed: seed &+ 0xABCD)
        let context = "seed \(seed):\n\(content)"
        let program: PDFNativeTextProgram
        do { program = try fixture.program(content) } catch {
            #expect(!legal, "legal content always parses: \(error) \(context)")
            return nil
        }
        let units: [PDFNativeReflow.Unit]
        do { units = try PDFNativeReflow.units(of: program) } catch {
            // Hostile content may be refused outright (drawing inside a path, stray
            // matrix operands): the page then stays exactly as it is.
            #expect(!legal, "legal content always yields units: \(error) \(context)")
            #expect(error is PDFNativeTextError || error is PDFNativeReflow.Refusal, "\(context)")
            return nil
        }
        let block = try chooseEdit(in: program, random: &random)
        let request = request(block, random: &random)
        let plan: (moving: [Int], offset: Double, region: CGRect)
        do { plan = try PDFNativeReflow.plan(request, units: units, page: pageBox) } catch let refusal as PDFNativeReflow.Refusal {
            // Deterministic: the same page refuses again, for the same reason.
            #expect(throws: refusal) { try PDFNativeReflow.plan(request, units: units, page: pageBox) }
            if refusal == .noRoom { #expect(request.delta > 0, "\(context)") }
            if refusal == .edgeOfPage { #expect(request.delta > 0, "only growing runs out of page: \(context)") }
            return nil
        }
        let again = try PDFNativeReflow.plan(request, units: units, page: pageBox)
        #expect(again.moving == plan.moving && again.offset == plan.offset && again.region == plan.region, "deterministic: \(context)")
        checkPlan(plan, request: request, units: units, context: context)
        let replacements: [Int: String]
        do {
            replacements = try PDFNativeReflow.replacements(moving: plan.moving, units: units, offset: plan.offset,
                                                            operations: program.operations, source: Array(program.data))
        } catch let refusal as PDFNativeReflow.Refusal {
            #expect(refusal == .fixedContent, "only an unmovable placement refuses here: \(context)")
            return nil
        }
        // Every replacement is its original operator plus a translation around it.
        let inserted: Set<String> = ["q", "cm", "Q", "Tm"]
        for (index, text) in replacements {
            var lexer = PDFNativeLexer(Data(text.utf8))
            var operations = try lexer.operations()
            if let original = operations.firstIndex(where: { $0.name == program.operations[index].name }) { operations.remove(at: original) }
            else { Issue.record("replacement drops its operator \(program.operations[index].name): \(context)") }
            for operation in operations {
                #expect(inserted.contains(operation.name), "only translations are added, not \(operation.name): \(context)")
                if operation.name == "cm" || operation.name == "Tm" {
                    let values = operation.operands.compactMap(\.number)
                    #expect(values.count == 6 && operation.operands.count == 6 && values.allSatisfy(\.isFinite), "\(text): \(context)")
                }
            }
            for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                #expect(!["nan", "-nan", "inf", "-inf", "infinity", "-infinity"].contains(token.lowercased()), "\(text): \(context)")
            }
        }
        // Rewrite with only the moves, and read the result again.
        for glyph in program.glyphs { glyph.selected = false }
        let graph = try PDFNativeObjectGraph(document: fixture.document)
        let (output, _) = try program.rewritten(using: graph, moving: replacements)
        let reread: PDFNativeTextProgram
        do { reread = try fixture.program(String(decoding: output, as: UTF8.self)) } catch {
            Issue.record("the rewritten stream no longer parses: \(error) \(context)\n→\n\(String(decoding: output, as: UTF8.self))")
            return nil
        }
        var depth = 0
        for operation in reread.operations {
            if operation.name == "q" { depth += 1 }
            if operation.name == "Q" { depth -= 1; #expect(depth >= 0, "\(context)") }
        }
        #expect(depth == 0, "q/Q stay balanced: \(context)")
        // Exactly the added operators: one translation per moved drawing, one text matrix per moved text object.
        func counts(_ operations: [PDFNativeOperation]) -> [String: Int] { operations.reduce(into: [:]) { $0[$1.name, default: 0] += 1 } }
        let before = counts(program.operations), after = counts(reread.operations)
        let wrapped = plan.moving.filter { if case .wrapped = units[$0].kind { true } else { false } }.count
        let texts = plan.moving.filter { if case .text = units[$0].kind { true } else { false } }.count
        #expect(after["q", default: 0] - before["q", default: 0] == wrapped, "\(context)")
        #expect(after["Q", default: 0] - before["Q", default: 0] == wrapped, "\(context)")
        #expect(after["cm", default: 0] - before["cm", default: 0] == wrapped, "\(context)")
        #expect(after["Tm", default: 0] - before["Tm", default: 0] == texts, "\(context)")
        if legal {
            // What moved moved by exactly the offset; nothing else moved at all.
            let moved = try PDFNativeReflow.units(of: reread)
            #expect(moved.count == units.count, "\(context)")
            let moving = Set(plan.moving)
            for (index, (old, new)) in zip(units, moved).enumerated() {
                let expected = moving.contains(index) ? old.bounds.offsetBy(dx: 0, dy: plan.offset) : old.bounds
                // Unbounded drawing (a shading with no clip) or drawing clipped away entirely.
                if expected.isInfinite || new.bounds.isInfinite || expected.isNull || new.bounds.isNull {
                    #expect(expected.isInfinite == new.bounds.isInfinite && expected.isNull == new.bounds.isNull, "\(context)"); continue
                }
                let tolerance = 0.002 + 1e-9 * max(abs(expected.minX), abs(expected.minY), abs(expected.maxX), abs(expected.maxY))
                let close = abs(new.bounds.minX - expected.minX) < tolerance && abs(new.bounds.minY - expected.minY) < tolerance
                    && abs(new.bounds.maxX - expected.maxX) < tolerance && abs(new.bounds.maxY - expected.maxY) < tolerance
                #expect(close, "unit \(index) \(moving.contains(index) ? "moved" : "stayed"): \(old.bounds) → \(new.bounds), expected \(expected); \(context)")
                #expect(old.clip == new.clip, "clips never move: \(context)")
            }
        }
        return (plan.moving, plan.offset, replacements)
    }

    @Test("Fuzz: legal pages plan soundly, and the rewritten stream moves exactly what was planned by exactly the offset",
          arguments: Array(UInt64(1)...UInt64(300)))
    func legalPages(seed: UInt64) throws {
        var composer = ReflowComposer(random: ReflowRandom(seed: seed), hostile: false)
        try exercise(composer.page(), seed: seed, legal: true)
    }

    @Test("Fuzz: hostile pages (non-finite and huge operands, singular matrices, broken nesting) never trap and never write unsound streams",
          arguments: Array(UInt64(1)...UInt64(300)))
    func hostilePages(seed: UInt64) throws {
        var composer = ReflowComposer(random: ReflowRandom(seed: seed), hostile: true)
        try exercise(composer.page(), seed: seed, legal: false)
    }

    @Test("Metamorphic: the same edit on a page translated by (dx, dy) moves the same drawing, the same way",
          arguments: Array(UInt64(1)...UInt64(120)))
    func translatedPage(seed: UInt64) throws {
        var composer = ReflowComposer(random: ReflowRandom(seed: seed), hostile: false)
        let content = composer.page()
        var shift = ReflowRandom(seed: seed ^ 0x5151)
        let dx = Double(Int.random(in: -60...60, using: &shift)), dy = Double(Int.random(in: -60...60, using: &shift))
        let fixture = try ReflowResources()
        let plain = try fixture.program(content), moved = try fixture.program("1 0 0 1 \(nativePDFNumber(dx)) \(nativePDFNumber(dy)) cm\n" + content)
        var random = ReflowRandom(seed: seed &+ 0xABCD)
        let block = try chooseEdit(in: plain, random: &random)
        // The same text object is the edited one on the translated page (one operator later).
        for (index, pieces) in plain.shows {
            for (piece, twin) in zip(pieces, moved.shows[index + 1] ?? []) {
                if case .glyph(let glyph) = piece, case .glyph(let other) = twin { other.selected = glyph.selected }
            }
        }
        let request = request(block, random: &random)
        let shifted = PDFNativeReflowRequest(delta: request.delta, block: block.offsetBy(dx: dx, dy: dy), minimumGap: request.minimumGap)
        let units = try PDFNativeReflow.units(of: plain), twins = try PDFNativeReflow.units(of: moved)
        #expect(units.count == twins.count)
        let context = "seed \(seed), shift (\(dx), \(dy)):\n\(content)"
        let first = Result { try PDFNativeReflow.plan(request, units: units, page: pageBox) }
        let second = Result { try PDFNativeReflow.plan(shifted, units: twins, page: pageBox.offsetBy(dx: dx, dy: dy)) }
        switch (first, second) {
        case (.success(let a), .success(let b)):
            #expect(a.moving == b.moving, "same moved set: \(context)")
            #expect(a.offset == b.offset, "\(context)")
            if !a.region.isNull {
                #expect(abs(a.region.minY + dy - b.region.minY) < 1e-6 && abs(a.region.maxY + dy - b.region.maxY) < 1e-6
                        && abs(a.region.minX + dx - b.region.minX) < 1e-6, "region translated: \(a.region) vs \(b.region) \(context)")
            }
            // The operators that move it are the same text, one operator later.
            let r1 = try? PDFNativeReflow.replacements(moving: a.moving, units: units, offset: a.offset, operations: plain.operations, source: Array(plain.data))
            let r2 = try? PDFNativeReflow.replacements(moving: b.moving, units: twins, offset: b.offset, operations: moved.operations, source: Array(moved.data))
            #expect(r1.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key + 1, $0.value) }) } == r2, "\(context)")
        case (.failure(let a), .failure(let b)):
            #expect(a as? PDFNativeReflow.Refusal == b as? PDFNativeReflow.Refusal, "same refusal: \(context)")
        default:
            Issue.record("one page refused and the translated one didn't: \(first) vs \(second); \(context)")
        }
    }

    @Test("Metamorphic: growing more moves a superset, and shrinking by the same amount moves the same drawing",
          arguments: Array(UInt64(1)...UInt64(150)))
    func monotoneAndSymmetric(seed: UInt64) throws {
        var composer = ReflowComposer(random: ReflowRandom(seed: seed), hostile: false)
        let content = composer.page()
        let fixture = try ReflowResources()
        let program = try fixture.program(content)
        var random = ReflowRandom(seed: seed &+ 0xABCD)
        let block = try chooseEdit(in: program, random: &random)
        let units = try PDFNativeReflow.units(of: program)
        let gap = [0.0, 6, 14][Int.random(in: 0..<3, using: &random)]
        let context = "seed \(seed):\n\(content)"
        var previous: Set<Int>?
        for amount in [3.0, 7, 14, 28, 56, 112] {
            let grow = try? PDFNativeReflow.plan(PDFNativeReflowRequest(delta: amount, block: block, minimumGap: gap), units: units, page: pageBox)
            if let grow {
                let moving = Set(grow.moving)
                if let previous { #expect(previous.isSubset(of: moving), "growing \(amount) moves at least what less growth moved: \(context)") }
                previous = moving
                do {
                    let shrink = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: -amount, block: block, minimumGap: gap), units: units, page: pageBox)
                    #expect(Set(shrink.moving) == moving, "shrinking \(amount) moves what growing \(amount) moves: \(context)")
                } catch let refusal as PDFNativeReflow.Refusal {
                    // Moving up can only leave a clip that moving down stayed inside.
                    #expect(refusal == .clipped, "\(refusal): \(context)")
                }
            } else {
                // Once growth is refused, more growth is refused too (checked on the next pass).
                previous = nil
            }
        }
    }

    // MARK: - Refusals end to end

    /// Two lines of the edited paragraph near the top, then `below`.
    private func pageWithParagraph(then below: String, top: Double = 700) -> String {
        "BT /F1 12 Tf 72 \(nativePDFNumber(top)) Td (Alpha paragraph line one) Tj ET\nBT /F1 12 Tf 72 \(nativePDFNumber(top - 14)) Td (Alpha paragraph line two) Tj ET\n" + below
    }

    private func edit(_ document: PDFDocument, delta: Double, destination: CGRect? = nil,
                      replacement: String = "Alpha paragraph line one Alpha paragraph line two") throws -> (document: PDFDocument, moved: PDFNativeReflowResult?) {
        let page = try #require(document.page(at: 0))
        let block = try #require(document.findString("line one", withOptions: []).first).bounds(for: page)
            .union(try #require(document.findString("line two", withOptions: []).first).bounds(for: page))
        let region = CGRect(x: 70, y: block.minY - 1, width: 404, height: block.maxY - block.minY + 2)
        let original = try #require(page.selection(for: region)?.string)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        return try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: region), originalText: original,
            replacement: NSAttributedString(string: replacement, attributes: [.font: font, .ligature: 0]),
            destination: PageRegion(pageIndex: 0, bounds: destination ?? CGRect(x: 72, y: region.minY - max(0, delta), width: 400, height: region.height + max(0, delta))),
            reflow: PDFNativeReflowRequest(delta: delta, block: region, minimumGap: 14))
    }

    private static let refusals: [(String, Double, PDFNativeReflow.Refusal)] = [
        // Lines every 14 pt down to the page's foot: nowhere to go.
        ((0..<45).map { "BT /F1 12 Tf 72 \(660 - $0 * 14) Td (Filler line \($0)) Tj ET" }.joined(separator: "\n"), 20, .edgeOfPage),
        // A side rule runs from above the paragraph's foot to below it.
        ("0.5 g 74 560 2 150 re f", 14, .straddles),
        // A clipped shading below.
        ("q 72 560 400 60 re W n /Sh sh Q", 14, .fixedContent),
        // Clipping text below.
        ("BT 7 Tr /F1 12 Tf 72 600 Td (Clipping text) Tj ET", 14, .fixedContent),
        // A singular placement below can't be expressed as a move.
        ("q 0 0 0 0 200 600 cm 0 0 10 10 re f Q", 14, .fixedContent),
        // Text tight inside a clip: moving it down would cut it off.
        ("q 72 655 400 30 re W n BT /F1 12 Tf 72 660 Td (Clipped line) Tj ET Q", 14, .clipped),
        // Moving up leaves a clip too.
        ("q 72 580 400 88 re W n BT /F1 12 Tf 72 660 Td (Clipped line) Tj ET Q", -14, .clipped),
    ]

    @Test("Every refusal, end to end: the editor throws its reason and the document is left exactly as it was",
          arguments: 0..<7)
    func refusalsEndToEnd(index: Int) throws {
        let (below, delta, refusal) = Self.refusals[index]
        let document = try ReflowPDF.document(content: pageWithParagraph(then: below))
        let before = try contents(document), page = document.page(at: 0)
        let text = document.string
        #expect(throws: PDFNativeReflowRefusal(message: refusal.message)) { try edit(document, delta: delta) }
        #expect(try contents(document) == before, "the source document is untouched")
        #expect(document.page(at: 0) === page)
        #expect(document.string == text)
    }

    /// Content written outside the grammar can't be wrapped or offset as a unit.
    private static let malformed: [String] = [
        // Text drawn inside an open path, which a later paint would otherwise wrap whole.
        "72 600 m BT /F1 12 Tf 72 620 Td (Inside a path) Tj ET 72 590 400 5 re f",
        // A colour change inside a path would be undone by the wrapping Q.
        "1 1 1 rg 72 600 m 0 0 0 rg 72 590 400 5 re f",
        // A coordinate change inside a text object would scale the injected move.
        "BT /F1 12 Tf 1 0 0 1 0 -5 cm 72 600 Td (Shifted line) Tj ET",
        // An image drawn inside a text object.
        "BT /F1 12 Tf 72 600 Td (Before) Tj q 20 0 0 20 72 560 cm /Im Do Q ET",
    ]

    @Test("Malformed content (drawing inside a path, a matrix inside text) is refused, and the document is untouched",
          arguments: 0..<4)
    func malformedRefused(index: Int) throws {
        let content = pageWithParagraph(then: Self.malformed[index])
        let document = try ReflowPDF.document(content: content)
        let before = try contents(document)
        #expect(throws: PDFNativeReflowRefusal.self) { try edit(document, delta: 14) }
        #expect(try contents(document) == before)
    }

    @Test("An image whose name isn't ASCII stays where it is rather than being renamed onto another resource")
    func rawByteNameRefused() throws {
        // `/ImX` becomes the raw bytes `/Im\u{E9}`; a lossy decode would read it as the second
        // resource, `/Im#EF#BF#BD`, and a rewrite would swap one image for the other.
        var data = ReflowPDF.data(content: pageWithParagraph(then: "q 20 0 0 20 72 600 cm /ImX Do Q"), xobjects: " /Im#EF#BF#BD 6 0 R")
        let marker = Data("/ImX Do".utf8)
        let range = try #require(data.range(of: marker))
        data.replaceSubrange(range, with: Data([0x2F, 0x49, 0x6D, 0xE9, 0x20, 0x44, 0x6F]))
        let document = try #require(PDFDocument(data: data))
        let before = try contents(document)
        #expect(throws: PDFNativeReflowRefusal(message: PDFNativeReflow.Refusal.fixedContent.message)) { try edit(document, delta: 14) }
        #expect(try contents(document) == before)
    }

    @Test("Many units in one tall row are grouped in linear time")
    func oneTallRowIsLinear() throws {
        let block = CGRect(x: 72, y: 700, width: 400, height: 30)
        // A tall rule first, then 100,000 small marks beside it: all one row.
        var units = [PDFNativeReflow.Unit(kind: .wrapped(first: 0, last: 0), bounds: CGRect(x: 80, y: 100, width: 1, height: 590),
                                          ctm: .identity, clip: nil, edited: false)]
        for index in 1...100_000 {
            units.append(PDFNativeReflow.Unit(kind: .wrapped(first: index, last: index), bounds: CGRect(x: 100, y: 200 + Double(index % 400), width: 5, height: 5),
                                              ctm: .identity, clip: nil, edited: false))
        }
        let clock = ContinuousClock(), start = clock.now
        let plan = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: 14, block: block, minimumGap: 14), units: units,
                                            page: CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(plan.moving.count == units.count)
        #expect(clock.now - start < .seconds(1), "\(clock.now - start)")
    }

    @Test("No room: a paragraph at the page's foot with nothing below can't grow past the bottom margin")
    func noRoomEndToEnd() throws {
        let document = try ReflowPDF.document(content: pageWithParagraph(then: "", top: 60))
        let before = try contents(document)
        #expect(throws: PDFNativeReflowRefusal(message: PDFNativeReflow.Refusal.noRoom.message)) { try edit(document, delta: 30) }
        #expect(try contents(document) == before)
        // Shrinking with nothing below just replaces the text.
        let (_, moved) = try edit(document, delta: -14, destination: CGRect(x: 72, y: 40, width: 400, height: 40))
        #expect(moved == nil)
    }

    @Test("A rotated page refuses reflow outright and changes nothing")
    func rotatedEndToEnd() throws {
        let document = try ReflowPDF.document(content: pageWithParagraph(then: "BT /F1 12 Tf 72 640 Td (Next paragraph) Tj ET"), rotation: 90)
        let before = try contents(document)
        #expect(throws: PDFNativeReflowRefusal(message: "Content can't move on a rotated page.")) { try edit(document, delta: 14) }
        #expect(try contents(document) == before)
    }

    @Test("The edited paragraph sharing a text object with what follows it can't move on its own")
    func sharedTextObject() throws {
        let content = "BT /F1 12 Tf 72 700 Td (Alpha paragraph line one) Tj 0 -14 Td (Alpha paragraph line two) Tj 0 -40 Td (Next paragraph shares it) Tj ET"
        let document = try ReflowPDF.document(content: content)
        #expect(throws: PDFNativeReflowRefusal(message: PDFNativeReflow.Refusal.straddles.message)) { try edit(document, delta: 14) }
    }

    /// The page's decoded content streams and the resources they use.
    private func page(_ document: PDFDocument) throws -> (data: Data, resources: CGPDFDictionaryRef?, owner: CGPDFDocument) {
        let bytes = try #require(document.dataRepresentation())
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let source = try #require(CGPDFDocument(provider))
        let dictionary = try #require(source.page(at: 1)?.dictionary)
        var data = Data()
        if let stream = nativeStream(dictionary, "Contents") { data = try nativeDecodedStream(stream) }
        else if let contents = nativeArray(dictionary, "Contents") {
            for index in 0..<CGPDFArrayGetCount(contents) {
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(contents, index, &stream), let stream { data.append(try nativeDecodedStream(stream)); data.append(10) }
            }
        }
        return (data, PDFNativeTextEditor.inheritedResources(dictionary), source)
    }

    private func contents(_ document: PDFDocument) throws -> Data { try page(document).data }

    /// The page's drawing re-read, for comparing positions before and after.
    private func drawing(_ document: PDFDocument) throws -> [PDFNativeReflow.Unit] {
        let (data, resources, owner) = try page(document)
        return try withExtendedLifetime(owner) { try PDFNativeReflow.units(of: PDFNativeTextProgram(data: data, resources: resources)) }
    }

    @Test("End to end: text, a path, an image and a form below all move by exactly the change; past the wide gap nothing moves")
    func everyKindMoves() throws {
        let below = [
            "BT /F1 12 Tf 72 640 Td (Next paragraph) Tj ET",
            "0.5 g 72 630 400 1 re f",
            "q 40 0 0 20 72 600 cm /Im Do Q",
            "q 1 0 0 1 200 595 cm /Fm Do Q",
            "BT /F1 12 Tf 72 400 Td (Far below the wide gap) Tj ET",
            "0 0 1 rg 72 380 400 2 re f",
        ].joined(separator: "\n")
        let document = try ReflowPDF.document(content: pageWithParagraph(then: below))
        let before = try drawing(document)
        let (edited, moved) = try edit(document, delta: 14, replacement: "Alpha paragraph line one Alpha paragraph line two Alpha paragraph line three, which is new")
        let result = try #require(moved)
        #expect(result.offset == -14)
        #expect(result.region.minY > 400, "the region stops above the wide gap: \(result.region)")
        let savedBytes = try #require(edited.dataRepresentation())
        let saved = try #require(PDFDocument(data: savedBytes))
        #expect(saved.string?.contains("which is new") == true)
        let after = try drawing(saved)
        // Each original drawing below is found again, 14 pt lower or where it was.
        func find(_ midY: Double, minX: Double, in units: [PDFNativeReflow.Unit]) -> PDFNativeReflow.Unit? {
            units.first { abs($0.bounds.midY - midY) < 0.01 && abs($0.bounds.minX - minX) < 0.01 }
        }
        for unit in before where unit.bounds.maxY < 660 {
            let movesToo = unit.bounds.minY > 500
            let found = find(unit.bounds.midY - (movesToo ? 14 : 0), minX: unit.bounds.minX, in: after)
            #expect(found != nil, "\(unit.kind) at \(unit.bounds) should \(movesToo ? "move 14 pt down" : "stay")")
            if let found { #expect(abs(found.bounds.width - unit.bounds.width) < 0.01 && abs(found.bounds.height - unit.bounds.height) < 0.01) }
        }
    }

    @Test("Shrinking end to end pulls every kind of drawing up by exactly the change")
    func everyKindShrinks() throws {
        let below = ["BT /F1 12 Tf 72 640 Td (Next paragraph) Tj ET", "0.5 g 72 630 400 1 re f",
                     "q 40 0 0 20 72 600 cm /Im Do Q", "q 1 0 0 1 200 595 cm /Fm Do Q"].joined(separator: "\n")
        let document = try ReflowPDF.document(content: pageWithParagraph(then: below))
        let before = try drawing(document)
        let (edited, moved) = try edit(document, delta: -14, destination: CGRect(x: 72, y: 690, width: 400, height: 25), replacement: "Alpha")
        #expect(try #require(moved).offset == 14)
        let savedBytes = try #require(edited.dataRepresentation())
        let after = try drawing(try #require(PDFDocument(data: savedBytes)))
        for unit in before where unit.bounds.maxY < 660 {
            #expect(after.contains { abs($0.bounds.midY - (unit.bounds.midY + 14)) < 0.01 && abs($0.bounds.minX - unit.bounds.minX) < 0.01 },
                    "\(unit.kind) at \(unit.bounds) should move 14 pt up")
        }
    }

    /// A line's bounds on `document`'s page.
    private func line(_ phrase: String, in document: PDFDocument) throws -> CGRect {
        let page = try #require(document.page(at: 0))
        return try #require(document.findString(phrase, withOptions: []).first).bounds(for: page)
    }

    @Test("Successive edits: re-editing a paragraph that was already edited once can still gain and lose lines")
    func reeditingAnEditedParagraph() throws {
        let below = "BT /F1 12 Tf 72 640 Td (Next paragraph) Tj ET\nBT /F1 12 Tf 72 300 Td (Far below) Tj ET"
        let document = try ReflowPDF.document(content: pageWithParagraph(then: below))
        let next = try line("Next paragraph", in: document)
        // First edit: a third line.
        let (once, _) = try edit(document, delta: 14, replacement: "Alpha paragraph line one Alpha paragraph line two Alpha paragraph and more")
        let onceBytes = try #require(once.dataRepresentation())
        let first = try #require(PDFDocument(data: onceBytes))
        #expect(abs(try line("Next paragraph", in: first).minY - (next.minY - 14)) < 0.05)
        // Second edit, of the edited paragraph: back to two lines. Its text now lives in the
        // replacement form; the paragraph must still be movable on its own.
        let page = try #require(first.page(at: 0))
        let block = try #require(first.findString("Alpha paragraph line one", withOptions: []).first).bounds(for: page)
            .union(try #require(first.findString("more", withOptions: []).first).bounds(for: page))
        let region = block.insetBy(dx: -1, dy: -1)
        let original = try #require(page.selection(for: region)?.string)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let (twice, moved) = try PDFNativeTextEditor.replace(in: first, region: PageRegion(pageIndex: 0, bounds: region), originalText: original,
            replacement: NSAttributedString(string: "Alpha paragraph, shorter now", attributes: [.font: font, .ligature: 0]),
            destination: PageRegion(pageIndex: 0, bounds: CGRect(x: region.minX, y: region.maxY - 20, width: 400, height: 20)),
            reflow: PDFNativeReflowRequest(delta: -14, block: region, minimumGap: 14))
        #expect(try #require(moved).offset == 14)
        let twiceBytes = try #require(twice.dataRepresentation())
        let second = try #require(PDFDocument(data: twiceBytes))
        #expect(abs(try line("Next paragraph", in: second).minY - next.minY) < 0.05, "the next paragraph is back where it began")
        #expect(abs(try line("Far below", in: second).minY - (try line("Far below", in: document)).minY) < 0.05)
    }

    @Test("Successive edits: growing a paragraph above one that was edited earlier moves the edited one too")
    func editedParagraphBelowMoves() throws {
        let below = "BT /F1 12 Tf 72 640 Td (Beta paragraph) Tj ET\nBT /F1 12 Tf 72 610 Td (Gamma paragraph) Tj ET\nBT /F1 12 Tf 72 300 Td (Far below) Tj ET"
        let document = try ReflowPDF.document(content: pageWithParagraph(then: below))
        let page = try #require(document.page(at: 0))
        // Edit Beta without changing its line count: it is now drawn by the replacement form.
        let beta = try line("Beta paragraph", in: document).insetBy(dx: -1, dy: -1)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let original = try #require(page.selection(for: beta)?.string)
        let edited = try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: beta), originalText: original,
            replacement: NSAttributedString(string: "Beta edited", attributes: [.font: font, .ligature: 0]),
            destination: PageRegion(pageIndex: 0, bounds: CGRect(x: 72, y: beta.minY - 2, width: 400, height: beta.height + 4)))
        let editedBytes = try #require(edited.dataRepresentation())
        let first = try #require(PDFDocument(data: editedBytes))
        let betaBefore = try line("Beta edited", in: first), gammaBefore = try line("Gamma paragraph", in: first)
        // Now grow Alpha, above it: Beta and Gamma both move down by the same 14 pt.
        let (grown, _) = try edit(first, delta: 14, replacement: "Alpha paragraph line one Alpha paragraph line two Alpha paragraph and more")
        let grownBytes = try #require(grown.dataRepresentation())
        let second = try #require(PDFDocument(data: grownBytes))
        #expect(abs(try line("Gamma paragraph", in: second).minY - (gammaBefore.minY - 14)) < 0.05)
        let betaAfter = try line("Beta edited", in: second)
        #expect(abs(betaAfter.minY - (betaBefore.minY - 14)) < 0.05, "the edited paragraph moves with the rest: \(betaBefore) → \(betaAfter)")
    }

    @Test("A transformation with extra operands is refused rather than read one way and rendered another; the page is untouched")
    func extraTransformationOperands() throws {
        // Twelve operands: the parser reads the first six and renderers the last six.
        let below = "q 1 0 0 1 0 0 1 0 0 1 0 -40 cm BT /F1 12 Tf 72 640 Td (Next paragraph) Tj ET Q"
        let document = try ReflowPDF.document(content: pageWithParagraph(then: below))
        let before = try contents(document)
        #expect(throws: PDFNativeReflowRefusal(message: PDFNativeReflow.Refusal.fixedContent.message)) {
            try edit(document, delta: 14, replacement: "Alpha paragraph line one Alpha paragraph line two Alpha paragraph and more")
        }
        #expect(try contents(document) == before)
    }

    // MARK: - Performance

    /// A page of `count` text objects: `perRow` to a row, rows 12 pt apart; with `tight`
    /// the rows overlap, so the whole page is one row of content. With `absolute`, each is
    /// placed by its own text matrix, as CoreGraphics writes them.
    private func crowdedPage(count: Int, perRow: Int, tight: Bool, absolute: Bool) -> String {
        (0..<count).map { index in
            let row = index / perRow, column = index % perRow
            let x = nativePDFNumber(72 + Double(column) * (300 / Double(perRow))), y = nativePDFNumber(720 - Double(row) * (tight ? 3 : 12))
            return absolute ? "BT /F1 1 Tf 9 0 0 9 \(x) \(y) Tm (ab) Tj ET" : "BT /F1 9 Tf \(x) \(y) Td (ab) Tj ET"
        }.joined(separator: "\n")
    }

    @Test("Performance: planning a page of 3,000 text objects stays well under 50 ms, and rewriting it stays linear",
          arguments: [(50, false, false), (3000, true, false), (50, false, true)])
    func crowdedPagePerformance(perRow: Int, tight: Bool, absolute: Bool) throws {
        let fixture = try ReflowResources()
        let program = try fixture.program(pageWithParagraph(then: "", top: 760) + crowdedPage(count: 3000, perRow: perRow, tight: tight, absolute: absolute))
        let block = CGRect(x: 72, y: 740, width: 400, height: 30)
        var planning: [Duration] = [], rewriting: [Duration] = [], moved = 0
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let units = try PDFNativeReflow.units(of: program)
            let plan = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: -14, block: block, minimumGap: 12), units: units, page: pageBox)
            let planned = ContinuousClock.now
            let replacements = try PDFNativeReflow.replacements(moving: plan.moving, units: units, offset: plan.offset,
                                                                operations: program.operations, source: Array(program.data))
            planning.append(planned - start); rewriting.append(ContinuousClock.now - planned)
            moved = plan.moving.count
            #expect(replacements.count == plan.moving.count * (absolute ? 2 : 1), "one text object start, plus its text matrix")
        }
        #expect(moved == 3000, "everything below moves up")
        let plan = planning.sorted()[2], rewrite = rewriting.sorted()[2]
        #expect(plan < .milliseconds(50), "planning median \(plan) over \(planning)")
        // Formatting numbers dominates the rewrite (about 8 µs each); this only guards against a blowup.
        #expect(rewrite < .seconds(1), "rewriting median \(rewrite) over \(rewriting)")
    }
}
