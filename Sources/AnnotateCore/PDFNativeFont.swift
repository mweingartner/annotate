import AppKit
import CoreGraphics
import CoreText

func nativeDictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? { var value: CGPDFDictionaryRef?; CGPDFDictionaryGetDictionary(dictionary, key, &value); return value }
func nativeArray(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? { var value: CGPDFArrayRef?; CGPDFDictionaryGetArray(dictionary, key, &value); return value }
func nativeStream(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? { var value: CGPDFStreamRef?; CGPDFDictionaryGetStream(dictionary, key, &value); return value }
func nativeName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? { var value: UnsafePointer<CChar>?; guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }; return String(cString: value) }
func nativeNumber(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Double? { var value: CGPDFReal = 0; guard CGPDFDictionaryGetNumber(dictionary, key, &value) else { return nil }; return Double(value) }
func nativeArrayNumber(_ array: CGPDFArrayRef, _ index: Int) -> Double? { var value: CGPDFReal = 0; guard CGPDFArrayGetNumber(array, index, &value) else { return nil }; return Double(value) }
func nativeDecodedStream(_ stream: CGPDFStreamRef) throws -> Data {
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { throw PDFNativeTextError.unsupported("The PDF text stream cannot be decoded by Core Graphics.") }
    guard CFDataGetLength(data) <= 64 * 1024 * 1024 else { throw PDFNativeTextError.unsupported("A PDF text stream exceeds the safe editing limit.") }
    return data as Data
}

struct PDFNativeGlyph {
    let bytes: [UInt8]
    let text: String
    let width: Double
    let wordSpace: Bool
}

/// Decodes source character codes independently of installed fonts. Widths use the PDF font's
/// own metrics; replacement glyphs are embedded separately by CoreText and never reuse subsets.
struct PDFNativeFont {
    private var unicode: [[UInt8]: String] = [:]
    private var codeLengths = [1]
    private var widths: [Int: Double] = [:]
    private var defaultWidth: Double?
    private var cidMap: [[UInt8]: Int] = [:]
    private var simpleEncoding: [Int: String] = [:]
    private var standardFont: CTFont?
    let vertical: Bool
    let baseName: String
    let ascent: Double
    let descent: Double
    /// The font descriptor's flags (fixed pitch 1, serif 2, italic 64, force bold 262144).
    let flags: Int

    init(_ dictionary: CGPDFDictionaryRef) throws {
        let subtype = nativeName(dictionary, "Subtype") ?? ""
        guard subtype != "Type3" else { throw PDFNativeTextError.unsupported("Type 3 glyph programs cannot yet be edited safely.") }
        baseName = nativeName(dictionary, "BaseFont") ?? "Unknown"
        let encodingName = nativeName(dictionary, "Encoding")
        vertical = encodingName?.hasSuffix("-V") == true
        guard !vertical else { throw PDFNativeTextError.unsupported("Vertical-writing PDF fonts are not yet supported for source text replacement.") }
        var metrics = dictionary
        if subtype == "Type0" {
            codeLengths = [2]
            var descendant: CGPDFDictionaryRef?
            guard let descendants = nativeArray(dictionary, "DescendantFonts"), CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { throw PDFNativeTextError.malformed("The composite font has no descendant font.") }
            metrics = descendant
            defaultWidth = nativeNumber(metrics, "DW") ?? 1000
            if let values = nativeArray(metrics, "W") {
                var i = 0
                while i < CGPDFArrayGetCount(values) {
                    guard let start = nativeArrayNumber(values, i), start >= 0, start <= 65535 else { throw PDFNativeTextError.malformed("Invalid CID font widths.") }
                    i += 1
                    var array: CGPDFArrayRef?
                    if CGPDFArrayGetArray(values, i, &array), let array {
                        for offset in 0..<CGPDFArrayGetCount(array) { if let width = nativeArrayNumber(array, offset) { widths[Int(start) + offset] = width } }
                        i += 1
                    } else {
                        guard let end = nativeArrayNumber(values, i), let width = nativeArrayNumber(values, i + 1), end >= start, end <= 65535, end - start <= 65536 else { throw PDFNativeTextError.malformed("Invalid CID width range.") }
                        for code in Int(start)...Int(end) { widths[code] = width }; i += 2
                    }
                }
            }
            if let encoding = nativeStream(dictionary, "Encoding") {
                let map = try Self.cmap(try nativeDecodedStream(encoding))
                guard !map.vertical else { throw PDFNativeTextError.unsupported("Vertical-writing CMaps are not yet supported for source text replacement.") }
                cidMap = map.cids
                if !map.lengths.isEmpty { codeLengths = map.lengths }
            } else if encodingName != "Identity-H" {
                throw PDFNativeTextError.unsupported("The source font uses a predefined CMap that does not expose its glyph metrics.")
            }
        } else {
            if let values = nativeArray(dictionary, "Widths") {
                let firstNumber = nativeNumber(dictionary, "FirstChar") ?? 0
                guard firstNumber >= 0, firstNumber <= 255 else { throw PDFNativeTextError.malformed("Invalid simple font character range.") }
                let first = Int(firstNumber)
                for index in 0..<CGPDFArrayGetCount(values) { if let width = nativeArrayNumber(values, index) { widths[first + index] = width } }
            }
            let descriptor = nativeDictionary(dictionary, "FontDescriptor")
            defaultWidth = descriptor.flatMap { nativeNumber($0, "MissingWidth") }
            var baseEncoding = encodingName ?? "StandardEncoding"
            let encoding = nativeDictionary(dictionary, "Encoding")
            if let encoding { baseEncoding = nativeName(encoding, "BaseEncoding") ?? baseEncoding }
            let stringEncoding: String.Encoding = baseEncoding == "MacRomanEncoding" ? .macOSRoman : .windowsCP1252
            for code in 0...255 {
                if let value = String(data: Data([UInt8(code)]), encoding: stringEncoding) { simpleEncoding[code] = value }
            }
            if baseEncoding == "StandardEncoding" {
                // Adobe StandardEncoding differs from Windows above ASCII. Never guess those codes.
                for code in 127...255 { simpleEncoding.removeValue(forKey: code) }
                simpleEncoding[39] = "’"; simpleEncoding[96] = "‘"
                for (code, name) in Self.standardNames { simpleEncoding[code] = Self.glyphName(name) }
            }
            if let encoding, let differences = nativeArray(encoding, "Differences") {
                var code = 0
                for index in 0..<CGPDFArrayGetCount(differences) {
                    if let value = nativeArrayNumber(differences, index) {
                        guard value >= 0, value <= 255 else { throw PDFNativeTextError.malformed("Invalid font encoding difference.") }
                        code = Int(value)
                    }
                    else {
                        var name: UnsafePointer<CChar>?
                        if CGPDFArrayGetName(differences, index, &name), let name {
                            simpleEncoding[code] = Self.glyphName(String(cString: name)); code += 1
                        }
                    }
                }
            }
            if widths.isEmpty {
                let name = baseName.split(separator: "+").last.map(String.init) ?? baseName
                let known = ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic", "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"]
                if known.contains(name) { standardFont = CTFontCreateWithName(name as CFString, 1000, nil) }
            }
        }
        let descriptor = nativeDictionary(metrics, "FontDescriptor")
        // Flags are a 32-bit field; anything else (a crafted huge or fractional number)
        // is ignored rather than converted, which would trap.
        flags = descriptor.flatMap { nativeNumber($0, "Flags") }
            .flatMap { $0.isFinite && $0 >= 0 && $0 <= Double(UInt32.max) ? Int($0) : nil } ?? 0
        ascent = descriptor.flatMap { nativeNumber($0, "Ascent") } ?? 800
        descent = descriptor.flatMap { nativeNumber($0, "Descent") } ?? -200
        if let map = nativeStream(dictionary, "ToUnicode") {
            let parsed = try Self.cmap(try nativeDecodedStream(map))
            unicode = parsed.unicode
            if !parsed.lengths.isEmpty { codeLengths = parsed.lengths }
            if !unicode.isEmpty { codeLengths = Array(Set(unicode.keys.map(\.count))).sorted(by: >) }
        }
    }

    func glyphs(_ bytes: [UInt8]) throws -> [PDFNativeGlyph] {
        var index = 0, result: [PDFNativeGlyph] = []
        while index < bytes.count {
            var matched: [UInt8]?
            for length in codeLengths.sorted(by: >) where index + length <= bytes.count {
                let key = Array(bytes[index..<index + length])
                if unicode.isEmpty || unicode[key] != nil { matched = key; break }
            }
            guard let encoded = matched, !encoded.isEmpty, encoded.count <= 4 else { throw PDFNativeTextError.unsupported("The selected source font has unmapped character codes.") }
            let code = encoded.reduce(0) { $0 * 256 + Int($1) }
            let cid = cidMap.isEmpty ? code : cidMap[encoded]
            guard let text = unicode[encoded] ?? (encoded.count == 1 ? simpleEncoding[code] : nil) else { throw PDFNativeTextError.unsupported("The source font does not provide a usable Unicode character map.") }
            var width = cid.flatMap { widths[$0] } ?? defaultWidth
            if width == nil, let standardFont {
                let characters = Array(text.utf16)
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                if CTFontGetGlyphsForCharacters(standardFont, characters, &glyphs, characters.count) {
                    var advances = [CGSize](repeating: .zero, count: glyphs.count)
                    CTFontGetAdvancesForGlyphs(standardFont, .horizontal, glyphs, &advances, glyphs.count)
                    width = advances.reduce(0) { $0 + $1.width }
                }
            }
            guard let width, width.isFinite else { throw PDFNativeTextError.unsupported("The source font is missing reliable glyph widths.") }
            result.append(PDFNativeGlyph(bytes: encoded, text: text, width: width, wordSpace: encoded == [32]))
            index += encoded.count
        }
        return result
    }

    struct CMap {
        var unicode: [[UInt8]: String] = [:]
        var cids: [[UInt8]: Int] = [:]
        var lengths: [Int] = []
        var vertical = false
    }
    static func cmap(_ data: Data) throws -> CMap {
        // Bound expansion work, including repeated/overlapping mappings. Limiting
        // each range alone permits a tiny CMap to perform billions of updates.
        guard data.count <= 16 * 1024 * 1024 else { throw PDFNativeTextError.malformed("The font CMap is too large.") }
        var lexer = PDFNativeLexer(data), tokens: [PDFNativeToken] = []
        while let token = try lexer.next() {
            guard tokens.count < 262_144 else { throw PDFNativeTextError.malformed("The font CMap has too many tokens.") }
            tokens.append(token)
        }
        var remainingMappings = 131_072, remainingBytes = 8 * 1024 * 1024
        func chargeMappings(_ count: Int) throws {
            guard count <= remainingMappings else { throw PDFNativeTextError.malformed("The font CMap exceeds the mapping limit.") }
            remainingMappings -= count
        }
        func chargeBytes(key: [UInt8], value: [UInt8]?) throws {
            let cost = key.count + (value?.count ?? 4) * 2
            guard cost <= remainingBytes else { throw PDFNativeTextError.malformed("The font CMap exceeds the decoded size limit.") }
            remainingBytes -= cost
        }
        var map = CMap(), i = 0
        while i < tokens.count {
            guard case .word(let word) = tokens[i] else { i += 1; continue }
            if word == "def", i >= 2, tokens[i - 2].name == "WMode", tokens[i - 1].number == 1 { map.vertical = true }
            if word == "usecmap", i > 0, tokens[i - 1].name != "Identity-H" {
                throw PDFNativeTextError.unsupported("The source character map inherits an unavailable predefined CMap.")
            }
            let countNumber = i > 0 ? (tokens[i - 1].number ?? 0) : 0
            guard countNumber >= 0, countNumber <= 65536 else { throw PDFNativeTextError.malformed("Invalid CMap range size.") }
            let count = Int(countNumber)
            i += 1
            if word == "begincodespacerange" {
                for _ in 0..<count where i + 1 < tokens.count { if let low = tokens[i].bytes { map.lengths.append(low.count) }; i += 2 }
            } else if word == "beginbfchar" || word == "begincidchar" {
                try chargeMappings(count)
                for _ in 0..<count where i + 1 < tokens.count {
                    if let key = tokens[i].bytes {
                        try chargeBytes(key: key, value: tokens[i + 1].bytes)
                        if let value = tokens[i + 1].bytes { map.unicode[key] = decodeUnicode(value) }
                        else if let cid = tokens[i + 1].number, cid >= 0, cid <= 65535 { map.cids[key] = Int(cid) }
                    }; i += 2
                }
            } else if word == "beginbfrange" || word == "begincidrange" {
                for _ in 0..<count where i + 2 < tokens.count {
                    guard let low = tokens[i].bytes, let high = tokens[i + 1].bytes, low.count == high.count, low.count <= 4 else { throw PDFNativeTextError.malformed("Invalid font CMap range.") }
                    let first = low.reduce(0) { $0 * 256 + Int($1) }, last = high.reduce(0) { $0 * 256 + Int($1) }
                    guard last >= first, last - first <= 65536 else { throw PDFNativeTextError.malformed("The font CMap range is too large.") }
                    try chargeMappings(last - first + 1)
                    for code in first...last {
                        let key = (0..<low.count).reversed().map { UInt8((code >> ($0 * 8)) & 255) }
                        let offset = code - first
                        if let array = tokens[i + 2].array, offset < array.count, let value = array[offset].bytes {
                            try chargeBytes(key: key, value: value)
                            map.unicode[key] = decodeUnicode(value)
                        }
                        else if let start = tokens[i + 2].bytes {
                            try chargeBytes(key: key, value: start)
                            var value = start, carry = offset
                            for position in value.indices.reversed() { let next = Int(value[position]) + carry; value[position] = UInt8(next & 255); carry = next >> 8 }
                            map.unicode[key] = decodeUnicode(value)
                        } else if let cid = tokens[i + 2].number, cid >= 0, cid + Double(offset) <= 65535 {
                            try chargeBytes(key: key, value: nil)
                            map.cids[key] = Int(cid) + offset
                        }
                    }; i += 3
                }
            }
        }
        map.lengths = Array(Set(map.lengths)); return map
    }
    private static func decodeUnicode(_ bytes: [UInt8]) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        return String(data: Data(bytes), encoding: .utf16BigEndian)
    }
    private static func glyphName(_ name: String) -> String? {
        let name = name.split(separator: ".").first.map(String.init) ?? name
        if name.count == 1 { return name }
        if name.contains("_") { let pieces = name.split(separator: "_").compactMap { glyphName(String($0)) }; return pieces.count == name.split(separator: "_").count ? pieces.joined() : nil }
        if name.hasPrefix("uni"), (name.count - 3) % 4 == 0 {
            let suffix = Array(name.dropFirst(3)), units = stride(from: 0, to: suffix.count, by: 4).compactMap { UInt16(String(suffix[$0..<$0 + 4]), radix: 16) }
            if units.count * 4 == suffix.count { return String(decoding: units, as: UTF16.self) }
        }
        if name.hasPrefix("u"), let scalar = UInt32(name.dropFirst(), radix: 16).flatMap(UnicodeScalar.init) { return String(scalar) }
        let accents = ["hungarumlaut": "\u{030B}", "circumflex": "\u{0302}", "dotaccent": "\u{0307}", "dieresis": "\u{0308}", "cedilla": "\u{0327}", "macron": "\u{0304}", "acute": "\u{0301}", "grave": "\u{0300}", "tilde": "\u{0303}", "breve": "\u{0306}", "ogonek": "\u{0328}", "caron": "\u{030C}", "ring": "\u{030A}"]
        for (suffix, accent) in accents where name.hasSuffix(suffix) && name.count > suffix.count {
            if let base = glyphName(String(name.dropLast(suffix.count))) { return (base + accent).precomposedStringWithCanonicalMapping }
        }
        return glyphNames[name]
    }
    private static let standardNames: [Int: String] = [161:"exclamdown",162:"cent",163:"sterling",164:"fraction",165:"yen",166:"florin",167:"section",168:"currency",169:"quotesingle",170:"quotedblleft",171:"guillemotleft",172:"guilsinglleft",173:"guilsinglright",174:"fi",175:"fl",177:"endash",178:"dagger",179:"daggerdbl",180:"periodcentered",182:"paragraph",183:"bullet",184:"quotesinglbase",185:"quotedblbase",186:"quotedblright",187:"guillemotright",188:"ellipsis",189:"perthousand",191:"questiondown",193:"grave",194:"acute",195:"circumflex",196:"tilde",197:"macron",198:"breve",199:"dotaccent",200:"dieresis",202:"ring",203:"cedilla",205:"hungarumlaut",206:"ogonek",207:"caron",208:"emdash",225:"AE",227:"ordfeminine",232:"Lslash",233:"Oslash",234:"OE",235:"ordmasculine",241:"ae",245:"dotlessi",248:"lslash",249:"oslash",250:"oe",251:"germandbls"]
    private static let glyphNames: [String: String] = ["space":" ","exclam":"!","quotedbl":"\"","numbersign":"#","dollar":"$","percent":"%","ampersand":"&","quotesingle":"'","quoteright":"’","quoteleft":"‘","parenleft":"(","parenright":")","asterisk":"*","plus":"+","comma":",","hyphen":"-","period":".","slash":"/","zero":"0","one":"1","two":"2","three":"3","four":"4","five":"5","six":"6","seven":"7","eight":"8","nine":"9","colon":":","semicolon":";","less":"<","equal":"=","greater":">","question":"?","at":"@","bracketleft":"[","backslash":"\\","bracketright":"]","asciicircum":"^","underscore":"_","grave":"`","braceleft":"{","bar":"|","braceright":"}","asciitilde":"~","exclamdown":"¡","cent":"¢","sterling":"£","fraction":"⁄","yen":"¥","florin":"ƒ","section":"§","currency":"¤","quotedblleft":"“","guillemotleft":"«","guilsinglleft":"‹","guilsinglright":"›","fi":"fi","fl":"fl","endash":"–","dagger":"†","daggerdbl":"‡","periodcentered":"·","paragraph":"¶","bullet":"•","quotesinglbase":"‚","quotedblbase":"„","quotedblright":"”","guillemotright":"»","ellipsis":"…","perthousand":"‰","questiondown":"¿","acute":"´","circumflex":"ˆ","tilde":"˜","macron":"¯","breve":"˘","dotaccent":"˙","dieresis":"¨","ring":"˚","cedilla":"¸","hungarumlaut":"˝","ogonek":"˛","caron":"ˇ","emdash":"—","AE":"Æ","ordfeminine":"ª","Lslash":"Ł","Oslash":"Ø","OE":"Œ","ordmasculine":"º","ae":"æ","dotlessi":"ı","lslash":"ł","oslash":"ø","oe":"œ","germandbls":"ß"]
}
