import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import AnnotateCore

/// What a saved page draws, read back from its bytes: every name drawn with `Do` at any
/// depth (resolved the way a renderer resolves it: a form's own resources, else the ones it
/// was drawn with), and the page's own XObject names nothing draws.
@MainActor
struct DrawnNames {
    /// Names drawn somewhere that resolve to nothing: content that silently disappears.
    private(set) var dangling: [String] = []
    /// Page-level XObject names drawn by the page or by a form that inherits the page's resources.
    private(set) var drawnAtPage: Set<String> = []
    /// Every page-level XObject name, with its decoded stream bytes.
    private(set) var pageObjects: [String: Data] = [:]

    init(_ data: Data) throws {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let page = try #require(document.page(at: 1)?.dictionary)
        let resources = PDFNativeTextEditor.inheritedResources(page)
        if let resources, let objects = nativeDictionary(resources, "XObject") {
            var names: [String] = []
            CGPDFDictionaryApplyBlock(objects, { key, _, _ in names.append(String(cString: key)); return true }, nil)
            for name in names { if let stream = nativeStream(objects, name) { pageObjects[name] = (try? nativeDecodedStream(stream)) ?? Data() } }
        }
        var content = Data()
        if let stream = nativeStream(page, "Contents") { content = try nativeDecodedStream(stream) }
        else if let array = nativeArray(page, "Contents") {
            for index in 0..<CGPDFArrayGetCount(array) {
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetStream(array, index, &stream), let stream else { continue }
                content.append(try nativeDecodedStream(stream)); content.append(10)
            }
        }
        try withExtendedLifetime(document) { try walk(content, resources: resources, pageLevel: true, depth: 0) }
    }

    private mutating func walk(_ data: Data, resources: CGPDFDictionaryRef?, pageLevel: Bool, depth: Int) throws {
        guard depth < 12 else { return }
        var lexer = PDFNativeLexer(data)
        for operation in try lexer.operations() where operation.name == "Do" {
            guard let name = operation.operands.first?.name else { continue }
            if pageLevel { drawnAtPage.insert(name) }
            guard let resources, let objects = nativeDictionary(resources, "XObject"), let stream = nativeStream(objects, name),
                  let dictionary = CGPDFStreamGetDictionary(stream) else { dangling.append(name); continue }
            guard nativeName(dictionary, "Subtype") == "Form" else { continue }
            let own = nativeDictionary(dictionary, "Resources")
            try walk(try nativeDecodedStream(stream), resources: own ?? resources, pageLevel: pageLevel && own == nil, depth: depth + 1)
        }
    }

    /// Page-level names nothing draws whose content still contains `phrase`.
    func undrawnHolding(_ phrase: String) -> [String] {
        let needle = Data(phrase.utf8)
        return pageObjects.filter { name, bytes in !drawnAtPage.contains(name) && bytes.range(of: needle) != nil }.keys.sorted()
    }
}

/// Alias pruning removes the names of an edited form or image so the old content does
/// not stay in the file, but must never remove a name something still draws.
@Suite("Alias pruning never removes a drawn name", .serialized)
@MainActor
struct NativeAliasPruningTests {
    static let catalog = "<< /Type /Catalog /Pages 2 0 R >>"
    static let pages = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
    static let fontResources = "/Resources << /Font << /F1 4 0 R >> >>"

    /// A form drawing `text` at (72, 600) in Helvetica.
    static func form(_ text: String, resources: String = fontResources, extra: String = "") -> String {
        HandPDF.stream("BT /F1 12 Tf 72 600 Td (\(text)) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] \(resources) \(extra)")
    }

    /// Replaces the occurrence of `phrase` nearest `y` (page space), as the editor does.
    static func edit(_ document: PDFDocument, _ phrase: String, nearY y: CGFloat? = nil, to replacement: String = "Public words") throws -> PDFDocument {
        let page = try #require(document.page(at: 0))
        let matches = document.findString(phrase, withOptions: []).map { $0.bounds(for: page) }
        let found = try #require(y.map { y in matches.min { abs($0.midY - y) < abs($1.midY - y) } } ?? matches.first)
        let region = found.insetBy(dx: -1, dy: -1)
        let original = try #require(page.selection(for: region)?.string)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        return try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: region), originalText: original,
            replacement: NSAttributedString(string: replacement, attributes: [.font: font, .ligature: 0]),
            destination: PageRegion(pageIndex: 0, bounds: CGRect(x: region.minX, y: region.minY - 4, width: 300, height: region.height + 8)), reflow: nil).document
    }

    static func count(_ phrase: String, in document: PDFDocument) -> Int { document.findString(phrase, withOptions: []).count }

    static func document(page resources: String, content: String, _ rest: [String]) throws -> PDFDocument {
        try #require(PDFDocument(data: HandPDF.data([catalog, pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> \(resources) >> /Contents 5 0 R >>",
            HandPDF.helvetica, HandPDF.stream(content)] + rest)))
    }

    static func saved(_ document: PDFDocument) throws -> DrawnNames { try DrawnNames(try #require(document.dataRepresentation())) }

    // MARK: One form, two names

    @Test("A form drawn under two names, both drawn: editing either instance keeps the other name", arguments: [600.0, 400.0])
    func bothNamesDrawn(editedY: Double) throws {
        // /Fm draws the form at y 600; /Alias draws the same object 200 points lower.
        let document = try Self.document(page: "/XObject << /Fm 6 0 R /Alias 6 0 R >>",
            content: "BT /F1 12 Tf 72 700 Td (Visible line) Tj ET q /Fm Do Q q 1 0 0 1 0 -200 cm /Alias Do Q", [Self.form("Secret words")])
        #expect(Self.count("Secret words", in: document) == 2)
        let edited = try Self.edit(document, "Secret words", nearY: editedY)
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        // The untouched instance still draws the old words, under whichever name it used.
        #expect(Self.count("Secret words", in: edited) == 1)
        #expect(Self.count("Public words", in: edited) == 1)
        #expect(Self.count("Visible line", in: edited) == 1)
        let kept = editedY == 600 ? "Alias" : "Fm", dropped = editedY == 600 ? "Fm" : "Alias"
        #expect(names.pageObjects[kept] != nil)
        #expect(names.pageObjects[dropped] == nil)
    }

    @Test("The same name drawn twice: editing one instance keeps the name for the other")
    func sameNameDrawnTwice() throws {
        let document = try Self.document(page: "/XObject << /Fm 6 0 R /Spare 6 0 R >>",
            content: "q /Fm Do Q q 1 0 0 1 0 -200 cm /Fm Do Q", [Self.form("Secret words")])
        let edited = try Self.edit(document, "Secret words", nearY: 600)
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(names.pageObjects["Fm"] != nil)
        // Spare is drawn by nothing and holds the old words: pruned.
        #expect(names.pageObjects["Spare"] == nil)
        #expect(Self.count("Secret words", in: edited) == 1)
        #expect(Self.count("Public words", in: edited) == 1)
    }

    // MARK: Inherited resources

    @Test("A form without its own resources that draws the alias keeps the alias")
    func inheritingFormDrawsAlias() throws {
        // W has no /Resources, so its "/Alias Do" resolves in the page's dictionary.
        let wrapper = HandPDF.stream("/Alias Do", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Matrix [1 0 0 1 0 -200]")
        let document = try Self.document(page: "/XObject << /Fm 6 0 R /Alias 6 0 R /W 7 0 R >>",
            content: "q /Fm Do Q q /W Do Q", [Self.form("Secret words"), wrapper])
        #expect(Self.count("Secret words", in: document) == 2)
        let edited = try Self.edit(document, "Secret words", nearY: 600)
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(names.pageObjects["Alias"] != nil)
        #expect(Self.count("Secret words", in: edited) == 1, "the wrapper's instance still draws")
        #expect(Self.count("Public words", in: edited) == 1)
    }

    @Test("A form without its own resources that draws the edited name itself keeps that name")
    func inheritingFormDrawsEditedName() throws {
        let wrapper = HandPDF.stream("/Fm Do", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Matrix [1 0 0 1 0 -200]")
        let document = try Self.document(page: "/XObject << /Fm 6 0 R /W 7 0 R >>",
            content: "q /Fm Do Q q /W Do Q", [Self.form("Secret words"), wrapper])
        #expect(Self.count("Secret words", in: document) == 2)
        let edited = try Self.edit(document, "Secret words", nearY: 600)
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "the wrapper still draws /Fm: \(names.dangling)")
        #expect(Self.count("Secret words", in: edited) == 1, "the wrapper's instance still draws")
        #expect(Self.count("Public words", in: edited) == 1)
    }

    @Test("A form with its own resources that happens to use the same name doesn't draw the page's alias")
    func ownResourcesShadowAlias() throws {
        // W has its own /Alias pointing at an unrelated form; the page's /Alias for the edited
        // form is drawn by nothing. Keeping it would only be over-cautious, never lossy: the
        // assertion that matters is that nothing dangles and W still draws its own content.
        let wrapper = HandPDF.stream("/Alias Do", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Matrix [1 0 0 1 0 -200] /Resources << /XObject << /Alias 8 0 R >> >>")
        let document = try Self.document(page: "/XObject << /Fm 6 0 R /Alias 6 0 R /W 7 0 R >>",
            content: "q /Fm Do Q q /W Do Q", [Self.form("Secret words"), wrapper, Self.form("Other words")])
        let edited = try Self.edit(document, "Secret words", nearY: 600)
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(Self.count("Other words", in: edited) == 1)
        #expect(Self.count("Public words", in: edited) == 1)
        #expect(Self.count("Secret words", in: edited) == 0)
        // W's /Alias is its own; the page's /Alias for the edited form is drawn by nothing.
        #expect(names.undrawnHolding("(Secret words)").isEmpty, "\(names.undrawnHolding("(Secret words)"))")
    }

    @Test("Text edited inside a form drawn by a form without resources leaves no undrawn name holding the old words")
    func inheritingWrapperRewritten() throws {
        // The page draws only W; W (no /Resources) draws /Fm, which the page also names /Alias.
        let wrapper = HandPDF.stream("/Fm Do", "/Type /XObject /Subtype /Form /BBox [0 0 612 792]")
        let document = try Self.document(page: "/XObject << /W 7 0 R /Fm 6 0 R /Alias 6 0 R >>",
            content: "q /W Do Q", [Self.form("Secret words"), wrapper])
        let edited = try Self.edit(document, "Secret words")
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(Self.count("Public words", in: edited) == 1)
        #expect(Self.count("Secret words", in: edited) == 0)
        withKnownIssue("an inheriting form that is rewritten gets its own resources; the page names it used are not pruned") {
            #expect(names.undrawnHolding("(Secret words)").isEmpty, "\(names.undrawnHolding("(Secret words)"))")
        }
    }

    // MARK: Nested forms

    @Test("Text edited inside a nested form prunes the inner alias from the outer form's resources")
    func nestedInnerAliasPruned() throws {
        let outer = HandPDF.stream("/Inner Do", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /XObject << /Inner 7 0 R /InnerAlias 7 0 R >> >>")
        let document = try Self.document(page: "/XObject << /Outer 6 0 R >>", content: "q /Outer Do Q", [outer, Self.form("Secret words")])
        let edited = try Self.edit(document, "Secret words")
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(Self.count("Secret words", in: edited) == 0)
        #expect(Self.count("Public words", in: edited) == 1)
        let bytes = try #require(edited.dataRepresentation())
        // No name, at any level, still reaches a stream holding the old words.
        #expect(!Self.reachableStreams(bytes).contains { $0.range(of: Data("(Secret words)".utf8)) != nil })
    }

    @Test("Inside a nested form, an inner alias still drawn by the outer form is kept")
    func nestedInnerAliasStillDrawn() throws {
        let outer = HandPDF.stream("/Inner Do q 1 0 0 1 0 -200 cm /InnerAlias Do Q",
            "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /XObject << /Inner 7 0 R /InnerAlias 7 0 R >> >>")
        let document = try Self.document(page: "/XObject << /Outer 6 0 R >>", content: "q /Outer Do Q", [outer, Self.form("Secret words")])
        #expect(Self.count("Secret words", in: document) == 2)
        let edited = try Self.edit(document, "Secret words", nearY: 600)
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(Self.count("Secret words", in: edited) == 1)
        #expect(Self.count("Public words", in: edited) == 1)
    }

    @Test("Text edited inside a form nested in a form without resources: the page alias drawn elsewhere stays")
    func nestedInheritingOuterKeepsPageAlias() throws {
        // Outer inherits the page's resources and draws /Inner; the page itself draws /Alias.
        let outer = HandPDF.stream("/Inner Do", "/Type /XObject /Subtype /Form /BBox [0 0 612 792]")
        let document = try Self.document(page: "/XObject << /Outer 6 0 R /Inner 7 0 R /Alias 7 0 R >>",
            content: "q /Outer Do Q q 1 0 0 1 0 -200 cm /Alias Do Q", [outer, Self.form("Secret words")])
        let edited = try Self.edit(document, "Secret words", nearY: 600)
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(names.pageObjects["Alias"] != nil)
        #expect(Self.count("Secret words", in: edited) == 1)
        #expect(Self.count("Public words", in: edited) == 1)
    }

    /// The decoded bytes of every stream reachable by name from the page, at any depth.
    static func reachableStreams(_ data: Data) -> [Data] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1)?.dictionary else { return [] }
        var result: [Data] = [], seen: Set<UInt> = []
        func visit(_ resources: CGPDFDictionaryRef?, depth: Int) {
            guard depth < 12, let resources, let objects = nativeDictionary(resources, "XObject") else { return }
            var names: [String] = []
            CGPDFDictionaryApplyBlock(objects, { key, _, _ in names.append(String(cString: key)); return true }, nil)
            for name in names {
                guard let stream = nativeStream(objects, name), seen.insert(UInt(bitPattern: stream.rawValue)).inserted else { continue }
                result.append((try? nativeDecodedStream(stream)) ?? Data())
                if let dictionary = CGPDFStreamGetDictionary(stream) { visit(nativeDictionary(dictionary, "Resources"), depth: depth + 1) }
            }
        }
        withExtendedLifetime(document) { visit(PDFNativeTextEditor.inheritedResources(page), depth: 0) }
        return result
    }

    // MARK: Images

    static func imageDocument(names: String, content: String, rest: [String] = []) throws -> PDFDocument {
        try #require(PDFDocument(data: HandPDF.data([catalog, pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << \(names) >> >> /Contents 5 0 R >>",
            HandPDF.stream("00FF00FF", "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode"),
            HandPDF.stream(content)] + rest)))
    }

    private static func reopened(_ document: PDFDocument) throws -> PDFDocument {
        let data = try #require(document.dataRepresentation())
        return try #require(PDFDocument(data: data))
    }

    @Test("An image edited while an alias of it is drawn elsewhere: the alias stays, by move and by removal", arguments: [false, true])
    func imageAliasDrawnElsewhere(remove: Bool) throws {
        let document = try Self.imageDocument(names: "/Im 4 0 R /Alias 4 0 R",
            content: "q 100 0 0 100 100 500 cm /Im Do Q q 100 0 0 100 300 200 cm /Alias Do Q")
        let images = try PDFNativeImageEditor.images(in: document, pageIndex: 0)
        #expect(images.count == 2)
        let first = try #require(images.first { abs($0.bounds.minY - 500) < 1 })
        let edited = remove ? try PDFNativeImageEditor.remove(in: document, image: first)
                            : try PDFNativeImageEditor.update(in: document, image: first, bounds: CGRect(x: 200, y: 600, width: 50, height: 50))
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(names.pageObjects["Alias"] != nil)
        let after = try PDFNativeImageEditor.images(in: try Self.reopened(edited), pageIndex: 0)
        #expect(after.count == (remove ? 1 : 2))
        #expect(after.contains { abs($0.bounds.minY - 200) < 1 && abs($0.bounds.minX - 300) < 1 }, "the aliased instance is untouched")
    }

    @Test("An image edited while a form without resources draws its alias: the alias stays")
    func imageAliasDrawnByInheritingForm() throws {
        let wrapper = HandPDF.stream("q 100 0 0 100 300 200 cm /Alias Do Q", "/Type /XObject /Subtype /Form /BBox [0 0 612 792]")
        let document = try Self.imageDocument(names: "/Im 4 0 R /Alias 4 0 R /W 6 0 R",
            content: "q 100 0 0 100 100 500 cm /Im Do Q q /W Do Q", rest: [wrapper])
        let images = try PDFNativeImageEditor.images(in: document, pageIndex: 0)
        #expect(images.count == 2)
        let first = try #require(images.first { abs($0.bounds.minY - 500) < 1 })
        let removed = try PDFNativeImageEditor.remove(in: document, image: first)
        let names = try Self.saved(removed)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(try PDFNativeImageEditor.images(in: try Self.reopened(removed), pageIndex: 0).count == 1)
    }

    @Test("An image edited with an alias nothing draws: the alias goes, so the old pixels leave the page")
    func imageUndrawnAliasPruned() throws {
        let document = try Self.imageDocument(names: "/Im 4 0 R /Spare 4 0 R", content: "q 100 0 0 100 100 500 cm /Im Do Q")
        let image = try #require(try PDFNativeImageEditor.images(in: document, pageIndex: 0).first)
        let removed = try PDFNativeImageEditor.remove(in: document, image: image)
        let names = try Self.saved(removed)
        #expect(names.dangling.isEmpty)
        #expect(names.pageObjects["Spare"] == nil && names.pageObjects["Im"] == nil)
    }

    @Test("An image inside a form, edited while the page draws the form's alias too: the alias stays")
    func imageInFormWithDrawnFormAlias() throws {
        let form = HandPDF.stream("q 100 0 0 100 100 500 cm /Im Do Q", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /XObject << /Im 4 0 R >> >>")
        let document = try Self.imageDocument(names: "/Fm 6 0 R /FmAlias 6 0 R",
            content: "q /Fm Do Q q 1 0 0 1 0 -300 cm /FmAlias Do Q", rest: [form])
        let images = try PDFNativeImageEditor.images(in: document, pageIndex: 0)
        #expect(images.count == 2)
        let upper = try #require(images.first { abs($0.bounds.minY - 500) < 1 })
        let removed = try PDFNativeImageEditor.remove(in: document, image: upper)
        let names = try Self.saved(removed)
        #expect(names.dangling.isEmpty, "\(names.dangling)")
        #expect(names.pageObjects["FmAlias"] != nil)
        let after = try PDFNativeImageEditor.images(in: try Self.reopened(removed), pageIndex: 0)
        #expect(after.count == 1)
        #expect(after.first.map { abs($0.bounds.minY - 200) < 1 } == true)
    }

    // MARK: Cost

    @Test("Pruning many aliases on a page with many operators stays fast", arguments: [(500, 50_000), (2_000, 100_000)])
    func manyAliasesManyOperators(aliases: Int, operators: Int) throws {
        // Every alias names the edited form; none is drawn. Each must be checked against the
        // page's operators, which must not cost aliases × operators.
        let names = (0..<aliases).map { "/A\($0) 6 0 R" }.joined(separator: " ")
        let filler = String(repeating: "0 g\n", count: operators)
        let document = try Self.document(page: "/XObject << /Fm 6 0 R \(names) >>", content: filler + "q /Fm Do Q", [Self.form("Secret words")])
        let clock = ContinuousClock(), start = clock.now
        let edited = try Self.edit(document, "Secret words")
        let time = clock.now - start
        let saved = try Self.saved(edited)
        #expect(saved.pageObjects.keys.allSatisfy { !$0.hasPrefix("A") || $0.hasPrefix("Annotate") }, "every undrawn alias pruned")
        #expect(time < .seconds(10), "\(aliases) aliases, \(operators) operators: \(time)")
    }

    @Test("Removing an image with many aliases on a page with many operators stays fast")
    func manyImageAliases() throws {
        let names = (0..<2_000).map { "/A\($0) 4 0 R" }.joined(separator: " ")
        let filler = String(repeating: "0 g\n", count: 100_000)
        let document = try Self.imageDocument(names: "/Im 4 0 R \(names)", content: filler + "q 100 0 0 100 100 500 cm /Im Do Q")
        let image = try #require(try PDFNativeImageEditor.images(in: document, pageIndex: 0).first)
        let clock = ContinuousClock(), start = clock.now
        let removed = try PDFNativeImageEditor.remove(in: document, image: image)
        let time = clock.now - start
        #expect(try Self.saved(removed).pageObjects.isEmpty, "every undrawn alias pruned")
        #expect(time < .seconds(10), "\(time)")
    }

    // MARK: Generated structures

    /// A page of one to three forms, each named one to three times, some drawn directly and
    /// some through a form without resources, all at distinct heights.
    @MainActor private struct Structure {
        static let words = ["Alpha", "Bravo", "Charlie"]
        var objects: [String] = []
        var names: [String] = []            // page XObject entries
        var instances: [(name: String, word: String, viaWrapper: Bool)] = []

        init(seed: UInt64) {
            var random = AliasRandom(seed: seed)
            let forms = Int.random(in: 1...3, using: &random)
            var formNames: [[String]] = []
            for form in 0..<forms {
                let own = Bool.random(using: &random)
                objects.append(NativeAliasPruningTests.form(Self.words[form], resources: own ? NativeAliasPruningTests.fontResources : ""))
                let aliases = (0..<Int.random(in: 1...3, using: &random)).map { "N\(form)x\($0)" }
                formNames.append(aliases)
                names += aliases.map { "/\($0) \(6 + form) 0 R" }
            }
            var draws: [(String, Int, Bool)] = []
            for (form, aliases) in formNames.enumerated() {
                for alias in aliases where Int.random(in: 0..<3, using: &random) > 0 { draws.append((alias, form, false)) }
            }
            for wrapper in 0..<Int.random(in: 0...2, using: &random) {
                let form = Int.random(in: 0..<forms, using: &random), alias = formNames[form].randomElement(using: &random)!
                objects.append(HandPDF.stream("/\(alias) Do", "/Type /XObject /Subtype /Form /BBox [0 0 612 792]"))
                names.append("/W\(wrapper) \(6 + forms + wrapper) 0 R")
                draws.append(("W\(wrapper)", form, true))
            }
            if draws.isEmpty { draws.append((formNames[0][0], 0, false)) }
            draws.shuffle(using: &random)
            instances = draws.map { (name: $0.0, word: Self.words[$0.1], viaWrapper: $0.2) }
        }

        var content: String {
            instances.enumerated().map { slot, instance in "q 1 0 0 1 0 -\(slot * 30) cm /\(instance.name) Do Q" }.joined(separator: "\n")
        }
    }

    @Test("Generated pages: an edit never leaves a drawn name dangling, and changes exactly one instance", arguments: Array(UInt64(1)...UInt64(40)))
    func generatedStructures(seed: UInt64) throws {
        let structure = Structure(seed: seed)
        let document = try Self.document(page: "/XObject << \(structure.names.joined(separator: " ")) >>", content: structure.content, structure.objects)
        var random = AliasRandom(seed: seed ^ 0xA11A5)
        let slot = Int.random(in: 0..<structure.instances.count, using: &random), target = structure.instances[slot]
        let before = Dictionary(uniqueKeysWithValues: Structure.words.map { ($0, Self.count($0, in: document)) })
        #expect(before[target.word] == structure.instances.filter { $0.word == target.word }.count, "seed \(seed): every instance is visible")
        let edited = try Self.edit(document, target.word, nearY: 600 - CGFloat(slot * 30) + 4, to: "Edited")
        let names = try Self.saved(edited)
        #expect(names.dangling.isEmpty, "seed \(seed): \(names.dangling) in \(structure.content)")
        #expect(Self.count("Edited", in: edited) == 1, "seed \(seed)")
        for word in Structure.words {
            #expect(Self.count(word, in: edited) == before[word]! - (word == target.word ? 1 : 0), "seed \(seed): \(word)")
        }
        // The edited word stays in the file only where something still draws it.
        if !target.viaWrapper && before[target.word] == 1 {
            #expect(names.undrawnHolding("(\(target.word))").isEmpty, "seed \(seed): \(names.undrawnHolding("(\(target.word))"))")
        }
    }
}

/// SplitMix64: every generated structure replays from its seed.
private struct AliasRandom: RandomNumberGenerator {
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
