import AppKit
import CoreGraphics
import CoreText
import PDFKit

public enum PDFNativeTextError: LocalizedError, Equatable {
    case permission, invalidSelection, sourceMismatch, replacementDoesNotFit, cannotWrite, scannedText
    case unsupported(String), malformed(String)
    public var errorDescription: String? {
        switch self {
        case .permission: "This PDF does not permit changing or copying its original content."
        case .invalidSelection: "Select a valid text area on one PDF page."
        case .sourceMismatch: "The selected text could not be mapped exactly to the PDF's original glyphs. Select a complete word or line and try again."
        case .replacementDoesNotFit: "The replacement text does not fit this area at the chosen font size. Enlarge the text area or reduce the size."
        case .cannotWrite: "The edited PDF could not be written and reopened."
        case .scannedText: "The selection is an invisible OCR layer. Choose Edit Scanned Text to replace its source image pixels and insert visible native text."
        case .unsupported(let message): "This PDF cannot be edited in place yet. " + message
        case .malformed(let message): "The PDF content is malformed. " + message
        }
    }
}

/// Rewrites original text-showing operators and imports embedded, selectable CoreText content.
/// It never covers original text with an annotation or rasterizes a source page.
@MainActor
public enum PDFNativeTextEditor {
    public static func replace(in document: PDFDocument, region: PageRegion, originalText: String,
                               replacement: NSAttributedString, destination: PageRegion? = nil) throws -> PDFDocument {
        try replaceContent(in: document, region: region, originalText: originalText, replacement: replacement, destination: destination,
                           scanMode: false, reflow: nil).document
    }

    /// Replaces text and moves the content below it by the edit's change in height (see
    /// `PDFNativeReflowRequest`), reporting what moved. Throws `PDFNativeReflowRefusal`
    /// when the content can't be moved safely; nothing is changed then.
    public static func replace(in document: PDFDocument, region: PageRegion, originalText: String, replacement: NSAttributedString,
                               destination: PageRegion, reflow: PDFNativeReflowRequest?) throws -> (document: PDFDocument, moved: PDFNativeReflowResult?) {
        try replaceContent(in: document, region: region, originalText: originalText, replacement: replacement, destination: destination,
                           scanMode: false, reflow: reflow)
    }

    /// Explicit scan mode edits only supported source image pixels and removes the matched OCR layer.
    public static func replaceScanned(in document: PDFDocument, region: PageRegion, originalText: String,
                                      replacement: NSAttributedString, destination: PageRegion? = nil) throws -> PDFDocument {
        try replaceContent(in: document, region: region, originalText: originalText, replacement: replacement, destination: destination,
                           scanMode: true, reflow: nil).document
    }

    private static func replaceContent(in document: PDFDocument, region: PageRegion, originalText: String,
                                       replacement: NSAttributedString, destination: PageRegion?, scanMode: Bool,
                                       reflow: PDFNativeReflowRequest?) throws -> (document: PDFDocument, moved: PDFNativeReflowResult?) {
        guard !document.isLocked, document.allowsDocumentChanges, document.allowsCopying else { throw PDFNativeTextError.permission }
        guard !document.isEncrypted else { throw PDFNativeTextError.unsupported("Native editing cannot preserve this document's encryption. Use an explicitly unencrypted working copy.") }
        guard let page = document.page(at: region.pageIndex), MarkerCodec.finite(region.bounds),
              region.bounds.width >= 1, region.bounds.height >= 1, page.bounds(for: .cropBox).contains(region.bounds),
              let bytes = document.dataRepresentation(), let provider = CGDataProvider(data: bytes as CFData),
              let source = CGPDFDocument(provider), let sourcePage = source.page(at: region.pageIndex + 1) else { throw PDFNativeTextError.invalidSelection }
        let destination = destination ?? region
        guard destination.pageIndex == region.pageIndex, MarkerCodec.finite(destination.bounds), destination.bounds.width >= 1,
              destination.bounds.height >= 1, page.bounds(for: .cropBox).contains(destination.bounds) else { throw PDFNativeTextError.invalidSelection }
        let graph = try PDFNativeObjectGraph(document: source)
        guard let pageDictionary = sourcePage.dictionary else { throw PDFNativeTextError.cannotWrite }
        guard let pageID = graph.objectID(for: pageDictionary), let value = graph[pageID],
              case .dictionary(var pageValues) = value else { throw PDFNativeTextError.cannotWrite }
        let resources = inheritedResources(pageDictionary)
        var data = Data()
        if let stream = nativeStream(pageDictionary, "Contents") { data = try nativeDecodedStream(stream) }
        else if let contents = nativeArray(pageDictionary, "Contents") {
            for index in 0..<CGPDFArrayGetCount(contents) {
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetStream(contents, index, &stream), let stream else { throw PDFNativeTextError.malformed("A page content array contains a non-stream object.") }
                data.append(try nativeDecodedStream(stream)); data.append(10)
            }
        }
        let program: PDFNativeTextProgram?
        if originalText.isEmpty {
            guard !scanMode else { throw PDFNativeTextError.invalidSelection }
            program = nil
        }
        else {
            let parsed = try PDFNativeTextProgram(data: data, resources: resources)
            try selectGlyphs(in: parsed, region: region.bounds, originalText: originalText, allowInvisible: scanMode)
            if scanMode { try PDFNativeScanPatch.prepare(program: parsed, region: region.bounds, graph: graph) }
            program = parsed
        }
        // Minimal reflow: the content below the paragraph moves by the change in height.
        var moving: [Int: String] = [:], moved: PDFNativeReflowResult?
        if let reflow, let program {
            guard page.rotation % 360 == 0 else { throw PDFNativeReflowRefusal(message: "Content can't move on a rotated page.") }
            do {
                let units = try PDFNativeReflow.units(of: program)
                let plan = try PDFNativeReflow.plan(reflow, units: units, page: page.bounds(for: .cropBox))
                if !plan.moving.isEmpty {
                    moving = try PDFNativeReflow.replacements(moving: plan.moving, units: units, offset: plan.offset,
                                                              operations: program.operations, source: Array(program.data))
                    moved = PDFNativeReflowResult(region: plan.region, offset: plan.offset)
                }
            } catch let refusal as PDFNativeReflow.Refusal {
                throw PDFNativeReflowRefusal(message: refusal.message)
            }
        }
        let replacementReference = replacement.length > 0
            ? try makeReplacement(replacement, bounds: destination.bounds, media: page.bounds(for: .mediaBox), graph: graph) : nil
        let rewritten: Data
        var pageResources: [String: PDFNativeValue] = [:]
        if let program {
            let insertion = try replacementReference.map { try program.insertion(reference: $0) }
            (rewritten, pageResources) = try program.rewritten(using: graph, insertion: insertion, moving: moving)
        } else {
            rewritten = data
            if let resources, case .dictionary(let values) = try graph.resolved(graph.importDictionary(resources)) { pageResources = values }
        }
        var contents: [PDFNativeValue] = []
        if !rewritten.isEmpty {
            contents.append(try graph.appendStream(data: Data("q\n".utf8), dictionary: [:]))
            contents.append(try graph.appendStream(data: rewritten, dictionary: [:]))
            contents.append(try graph.appendStream(data: Data("\nQ\n".utf8), dictionary: [:]))
        }
        if program == nil, let replacementReference {
            var objects: [String: PDFNativeValue] = [:]
            if let existing = pageResources["XObject"], case .dictionary(let values) = try graph.resolved(existing) { objects = values }
            var name = "AnnotateReplacementText"
            while objects[name] != nil { name += "x" }
            objects[name] = replacementReference; pageResources["XObject"] = .dictionary(objects)
            contents.append(try graph.appendStream(data: Data("q /\(name) Do Q\n".utf8), dictionary: [:]))
        }
        pageValues["Contents"] = .array(contents)
        pageValues["Resources"] = .dictionary(pageResources)
        graph[pageID] = .dictionary(pageValues)
        let output = try graph.write()
        guard let result = PDFDocument(data: output), result.pageCount == document.pageCount,
              let editedPage = result.page(at: region.pageIndex), editedPage.rotation == page.rotation,
              editedPage.bounds(for: .cropBox) == page.bounds(for: .cropBox) else { throw PDFNativeTextError.cannotWrite }
        return (result, moved)
    }

    private static func makeReplacement(_ replacement: NSAttributedString, bounds: CGRect, media: CGRect,
                                        graph: PDFNativeObjectGraph) throws -> PDFNativeValue {
        let generated = try replacementPDF(replacement, bounds: bounds, media: media)
        guard let provider = CGDataProvider(data: generated as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1), let dictionary = page.dictionary else { throw PDFNativeTextError.cannotWrite }
        graph.retain(document)
        var resources: [String: PDFNativeValue] = [:]
        if let sourceResources = inheritedResources(dictionary), case .dictionary(let imported) = try graph.resolved(graph.importDictionary(sourceResources)) { resources = imported }
        var states: [String: PDFNativeValue] = [:]
        if let existing = resources["ExtGState"], case .dictionary(let values) = try graph.resolved(existing) { states = values }
        var stateName = "AnnotateReplacementState"
        while states[stateName] != nil { stateName += "x" }
        states[stateName] = .dictionary(["Type": .name("ExtGState"), "ca": .number(1), "CA": .number(1), "BM": .name("Normal"), "SMask": .name("None")])
        resources["ExtGState"] = .dictionary(states)
        var data = Data()
        if let stream = nativeStream(dictionary, "Contents") { data = try nativeDecodedStream(stream) }
        else if let array = nativeArray(dictionary, "Contents") {
            for index in 0..<CGPDFArrayGetCount(array) {
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetStream(array, index, &stream), let stream else { throw PDFNativeTextError.cannotWrite }
                data.append(try nativeDecodedStream(stream)); data.append(10)
            }
        }
        // PDF Forms inherit the invoking graphics/text state. In particular, OCR
        // may use invisible rendering or zero alpha; replacement styles start clean.
        data = Data("/\(stateName) gs BT 0 Tr 0 Tc 0 Tw 100 Tz 0 Ts ET\n".utf8) + data
        return try graph.appendStream(data: data, dictionary: ["Type": .name("XObject"), "Subtype": .name("Form"), "FormType": .integer(1),
            "BBox": .array([.number(media.minX), .number(media.minY), .number(media.maxX), .number(media.maxY)]), "Resources": .dictionary(resources)])
    }

    static func inheritedResources(_ dictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var current: CGPDFDictionaryRef? = dictionary, seen: Set<UInt> = []
        while let value = current, seen.insert(UInt(bitPattern: value.rawValue)).inserted {
            if let resources = nativeDictionary(value, "Resources") { return resources }
            current = nativeDictionary(value, "Parent")
        }
        return nil
    }

    static func selectGlyphs(in program: PDFNativeTextProgram, region: CGRect, originalText: String, allowInvisible: Bool = false) throws {
        // Region matching avoids changing another occurrence of the same word elsewhere on a page.
        let candidates = program.glyphs.filter { glyph in
            let intersection = glyph.bounds.intersection(region.insetBy(dx: -0.5, dy: -0.5))
            return !intersection.isNull && intersection.width > min(glyph.bounds.width * 0.5, 0.5)
                && intersection.height > glyph.bounds.height * 0.35
        }
        let target = normalized(originalText)
        guard !target.isEmpty else { throw PDFNativeTextError.invalidSelection }
        let strings = candidates.map { normalized($0.glyph.text) }
        let combined = strings.joined()
        guard let range = combined.range(of: target), combined.range(of: target, range: range.upperBound..<combined.endIndex) == nil else { throw PDFNativeTextError.sourceMismatch }
        let lower = combined[..<range.lowerBound].utf16.count, upper = lower + target.utf16.count
        var cursor = 0, selected: [PDFNativeGlyphPlacement] = []
        for (glyph, text) in zip(candidates, strings) {
            let end = cursor + text.utf16.count
            if end > lower, cursor < upper {
                // Ligatures are indivisible source glyphs; never erase unselected characters.
                guard cursor >= lower, end <= upper else { throw PDFNativeTextError.sourceMismatch }
                selected.append(glyph)
            } else if text.isEmpty, cursor > lower, cursor < upper { selected.append(glyph) }
            cursor = end
        }
        guard !selected.isEmpty else { throw PDFNativeTextError.sourceMismatch }
        guard !selected.contains(where: \.clipping) else { throw PDFNativeTextError.unsupported("Selected text defines a clipping path for other artwork.") }
        guard allowInvisible || !selected.contains(where: \.invisible) else { throw PDFNativeTextError.scannedText }
        func hasActualText(_ node: PDFNativeTextProgram) -> Bool { node.markedActualText || node.forms.values.contains(where: hasActualText) }
        guard !hasActualText(program) else { throw PDFNativeTextError.unsupported("The page contains replacement accessibility text that cannot yet be updated safely.") }
        selected.forEach { $0.selected = true }
    }

    private static func normalized(_ text: String) -> String {
        text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    private static func replacementPDF(_ source: NSAttributedString, bounds: CGRect, media: CGRect) throws -> Data {
        let text = NSMutableAttributedString(attributedString: source)
        let all = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: all) { value, range, _ in
            if value == nil { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), CGPath(rect: bounds, transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.location + visible.length == text.length else { throw PDFNativeTextError.replacementDoesNotFit }
        let output = NSMutableData(); var box = media
        guard let consumer = CGDataConsumer(data: output as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PDFNativeTextError.cannotWrite }
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.endPDFPage(); context.closePDF()
        return output as Data
    }
}
