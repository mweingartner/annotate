import AppKit
import PDFKit

/// Native OpenXML exports with explicit semantic limits: XLSX is text cells; PPTX is page images.
@MainActor
public enum PDFOfficeExporter {
    public static func spreadsheet(_ document: PDFDocument) throws -> Data {
        try PDFConversion.validate(document)
        guard document.pageCount <= 20_000 else { throw PDFConversionError.inputTooLarge }
        var entries: [(String, Data)] = []
        var sheets = "", relations = "", overrides = ""
        var bytes = 0
        var containsText = false
        let separator = try NSRegularExpression(pattern: "(?:\\t+| {2,})")
        for index in 0..<document.pageCount {
            let number = index + 1
            guard let page = document.page(at: index) else { throw AnnotateError.invalidPage(index) }
            let text = try PDFPageText.attributedText(from: page).string
            containsText = containsText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard text.utf8.count <= 128 * 1_024 * 1_024 else { throw PDFConversionError.inputTooLarge }
            let lines = text.components(separatedBy: .newlines)
            guard lines.count <= 1_048_576 else { throw PDFConversionError.inputTooLarge }
            var rows = ""
            var maxColumn = 1
            for (row, line) in lines.enumerated() {
                let split = separator.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "\t")
                let cells = split.components(separatedBy: "\t")
                guard cells.count <= 16_384 else { throw PDFConversionError.inputTooLarge }
                maxColumn = max(maxColumn, cells.count)
                var cellXML = ""
                for (column, cell) in cells.enumerated() where !cell.isEmpty {
                    guard cell.utf16.count <= 32_767 else { throw PDFConversionError.inputTooLarge }
                    // Inline strings preserve leading zeros and prohibit formula execution from PDF text.
                    cellXML += "<c r=\"\(columnName(column))\(row + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(cell))</t></is></c>"
                }
                let lineCount = cells.map { max(1, Int(ceil(Double($0.count) / 52))) }.max() ?? 1
                let rowHeight = min(409, lineCount * 16)
                rows += "<row r=\"\(row + 1)\" ht=\"\(rowHeight)\" customHeight=\"1\">\(cellXML)</row>"
            }
            let worksheet = "\(header)<worksheet xmlns=\"\(spreadsheetNS)\"><cols><col min=\"1\" max=\"\(maxColumn)\" width=\"56\" customWidth=\"1\"/></cols><sheetData>\(rows)</sheetData></worksheet>"
            let data = Data(worksheet.utf8)
            bytes += data.count
            guard bytes <= PDFOfficeZIP.maximumBytes / 2 else { throw PDFConversionError.inputTooLarge }
            entries.append(("xl/worksheets/sheet\(number).xml", data))
            sheets += "<sheet name=\"Page \(number)\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            relations += relationship("rId\(number)", type: "worksheet", target: "worksheets/sheet\(number).xml")
            overrides += contentOverride("/xl/worksheets/sheet\(number).xml", type: "spreadsheetml.worksheet+xml")
        }
        guard containsText else { throw PDFConversionError.noText }
        entries.append(("xl/styles.xml", Data(spreadsheetStyles.utf8)))
        relations += relationship("rIdStyles", type: "styles", target: "styles.xml")
        overrides += contentOverride("/xl/styles.xml", type: "spreadsheetml.styles+xml")
        entries.append(("xl/workbook.xml", Data("\(header)<workbook xmlns=\"\(spreadsheetNS)\" xmlns:r=\"\(relationshipNS)\"><sheets>\(sheets)</sheets></workbook>".utf8)))
        entries.append(("xl/_rels/workbook.xml.rels", Data(relationships(relations).utf8)))
        entries.append(("_rels/.rels", Data(relationships(relationship("rId1", type: "officeDocument", target: "xl/workbook.xml")).utf8)))
        entries.append(("[Content_Types].xml", Data(contentTypes(contentOverride("/xl/workbook.xml", type: "spreadsheetml.sheet.main+xml") + overrides).utf8)))
        return try PDFOfficeZIP.archive(entries)
    }

    public static func presentation(_ document: PDFDocument) throws -> Data {
        try PDFConversion.validate(document, needsPrinting: true)
        guard document.pageCount <= 2_000, let first = document.page(at: 0) else { throw PDFConversionError.inputTooLarge }
        let firstSize = try PDFConversion.displayedSize(of: first)
        let longest = max(firstSize.width, firstSize.height)
        let slideWidth = max(914_400, Int(9_144_000 * firstSize.width / longest))
        let slideHeight = max(914_400, Int(9_144_000 * firstSize.height / longest))
        var entries: [(String, Data)] = []
        var slideIDs = "", slideRelationships = "", overrides = ""
        var imageBytes = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw AnnotateError.invalidPage(index) }
            let number = index + 1
            let size = try PDFConversion.displayedSize(of: page)
            let ratio = min(Double(slideWidth) / size.width, Double(slideHeight) / size.height)
            let width = Int(size.width * ratio), height = Int(size.height * ratio)
            let x = (slideWidth - width) / 2, y = (slideHeight - height) / 2
            // Each page's render is released before the next; together they peaked near 1 GB.
            let image = try autoreleasepool { try PDFConversion.imageData(page: page, format: .png, scale: 2) }
            imageBytes += image.count
            guard imageBytes <= PDFOfficeZIP.maximumBytes - 8 * 1_024 * 1_024 else { throw PDFConversionError.inputTooLarge }
            entries.append(("ppt/media/page\(number).png", image))
            let picture = "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"PDF page \(number)\" descr=\"Rendered PDF page \(number)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            let slide = "\(header)<p:sld \(presentationNamespaces)><p:cSld name=\"PDF page \(number)\"><p:spTree>\(groupShape)\(picture)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            entries.append(("ppt/slides/slide\(number).xml", Data(slide.utf8)))
            entries.append(("ppt/slides/_rels/slide\(number).xml.rels", Data(relationships(relationship("rId1", type: "slideLayout", target: "../slideLayouts/slideLayout1.xml") + relationship("rId2", type: "image", target: "../media/page\(number).png")).utf8)))
            slideIDs += "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(number + 2)\"/>"
            slideRelationships += relationship("rId\(number + 2)", type: "slide", target: "slides/slide\(number).xml")
            overrides += contentOverride("/ppt/slides/slide\(number).xml", type: "presentationml.slide+xml")
        }
        let presentation = "\(header)<p:presentation \(presentationNamespaces)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx=\"\(slideWidth)\" cy=\"\(slideHeight)\" type=\"custom\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        entries.append(("ppt/presentation.xml", Data(presentation.utf8)))
        entries.append(("ppt/_rels/presentation.xml.rels", Data(relationships(relationship("rId1", type: "slideMaster", target: "slideMasters/slideMaster1.xml") + relationship("rId2", type: "presProps", target: "presProps.xml") + slideRelationships).utf8)))
        entries.append(("ppt/presProps.xml", Data("\(header)<p:presentationPr \(presentationNamespaces)/>".utf8)))
        entries.append(("ppt/slideMasters/slideMaster1.xml", Data(slideMaster.utf8)))
        entries.append(("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(relationships(relationship("rId1", type: "slideLayout", target: "../slideLayouts/slideLayout1.xml") + relationship("rId2", type: "theme", target: "../theme/theme1.xml")).utf8)))
        entries.append(("ppt/slideLayouts/slideLayout1.xml", Data(slideLayout.utf8)))
        entries.append(("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(relationships(relationship("rId1", type: "slideMaster", target: "../slideMasters/slideMaster1.xml")).utf8)))
        entries.append(("ppt/theme/theme1.xml", Data(theme.utf8)))
        entries.append(("_rels/.rels", Data(relationships(relationship("rId1", type: "officeDocument", target: "ppt/presentation.xml")).utf8)))
        overrides += contentOverride("/ppt/presentation.xml", type: "presentationml.presentation.main+xml")
        overrides += contentOverride("/ppt/presProps.xml", type: "presentationml.presProps+xml")
        overrides += contentOverride("/ppt/slideMasters/slideMaster1.xml", type: "presentationml.slideMaster+xml")
        overrides += contentOverride("/ppt/slideLayouts/slideLayout1.xml", type: "presentationml.slideLayout+xml")
        overrides += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        entries.append(("[Content_Types].xml", Data(contentTypes(overrides, png: true).utf8)))
        return try PDFOfficeZIP.archive(entries)
    }

    private static var spreadsheetStyles: String {
        "\(header)<styleSheet xmlns=\"\(spreadsheetNS)\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Arial\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
    }

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let spreadsheetNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let presentationNamespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    private static let groupShape = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    private static let colorMap = "<p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/>"
    private static var slideMaster: String { "\(header)<p:sldMaster \(presentationNamespaces)><p:cSld><p:spTree>\(groupShape)</p:spTree></p:cSld>\(colorMap)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>" }
    private static var slideLayout: String { "\(header)<p:sldLayout \(presentationNamespaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(groupShape)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>" }
    private static var theme: String {
        let names = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]
        let colors = ["000000", "FFFFFF", "222222", "EEEEEE", "006B66", "4472C4", "70AD47", "FFC000", "ED7D31", "7030A0", "0563C1", "954F72"]
        let scheme = zip(names, colors).map { "<a:\($0)><a:srgbClr val=\"\($1)\"/></a:\($0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(fill)<a:prstDash val=\"solid\"/></a:ln>"
        return "\(header)<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Annotate\"><a:themeElements><a:clrScheme name=\"Annotate\">\(scheme)</a:clrScheme><a:fontScheme name=\"Annotate\"><a:majorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Annotate\"><a:fillStyleLst>\(String(repeating: fill, count: 3))</a:fillStyleLst><a:lnStyleLst>\(String(repeating: line, count: 3))</a:lnStyleLst><a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst><a:bgFillStyleLst>\(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    }

    private static func contentTypes(_ overrides: String, png: Bool = false) -> String {
        "\(header)<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(png ? "<Default Extension=\"png\" ContentType=\"image/png\"/>" : "")\(overrides)</Types>"
    }
    private static func contentOverride(_ part: String, type: String) -> String { "<Override PartName=\"\(part)\" ContentType=\"application/vnd.openxmlformats-officedocument.\(type)\"/>" }
    private static func relationships(_ content: String) -> String { "\(header)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(content)</Relationships>" }
    private static func relationship(_ id: String, type: String, target: String) -> String { "<Relationship Id=\"\(id)\" Type=\"\(relationshipNS)/\(type)\" Target=\"\(target)\"/>" }
    private static func columnName(_ index: Int) -> String {
        var number = index + 1, result = ""
        while number > 0 {
            number -= 1
            result = String(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")[number % 26]) + result
            number /= 26
        }
        return result
    }
    private static func xml(_ text: String) -> String {
        let valid = String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value) })
        return valid.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&quot;").replacing("'", with: "&apos;")
    }
}
