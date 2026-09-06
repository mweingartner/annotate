import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Visible edited page text", .serialized)
@MainActor
struct PageTextTests {
    @Test("Extraction preserves body styling and orders visible supplemental text without marker badges or passwords")
    func semanticText() throws {
        let document = try fixture()
        let page = try #require(document.page(at: 0))
        let body = try #require(page.attributedString)
        let result = try PDFPageText.attributedText(from: page)
        #expect(result.attributedSubstring(from: NSRange(location: 0, length: body.length)).isEqual(to: body))
        let text = result.string
        let first = try #require(text.range(of: "LiveEditSentinel"))
        let second = try #require(text.range(of: "ForeignTextSentinel"))
        let third = try #require(text.range(of: "FieldValueSentinel"))
        let fourth = try #require(text.range(of: "VisibleChoiceSentinel"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < third.lowerBound)
        #expect(third.lowerBound < fourth.lowerBound)
        for excluded in ["HiddenSentinel", "MarkerBadgeSentinel", "PasswordSentinel", "OutsideSentinel", "export-code"] {
            #expect(!text.contains(excluded))
        }
        #expect(text.contains("[Text field: Name]"))
        #expect(text.contains("[Choice field: Status]"))
    }

    @Test("Live edits and filled fields survive every offered text export", arguments: [PDFConversionFormat.docx, .doc, .odt, .rtf, .text, .html, .xlsx])
    func textExports(format: PDFConversionFormat) throws {
        let data = try PDFConversion.exportData(document: fixture(), format: format)
        let text: String
        if format == .xlsx {
            // The native XLSX ZIP writer stores XML without compression; independent
            // OfficeExportTests validate its CRCs and XML relationships.
            text = String(decoding: data, as: UTF8.self)
        } else {
            let type: NSAttributedString.DocumentType = switch format {
            case .docx: .officeOpenXML
            case .doc: .docFormat
            case .odt: .openDocument
            case .rtf: .rtf
            case .html: .html
            default: .plain
            }
            text = try NSAttributedString(data: data, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil).string
        }
        for included in ["BodySentinel", "LiveEditSentinel", "ForeignTextSentinel", "FieldValueSentinel", "VisibleChoiceSentinel"] {
            #expect(text.contains(included))
        }
        for excluded in ["HiddenSentinel", "MarkerBadgeSentinel", "PasswordSentinel", "OutsideSentinel"] {
            #expect(!text.contains(excluded))
        }
    }

    @Test("A page with only live text or fields remains usable for text and Excel export")
    func annotationOnly() throws {
        let source = try fixture()
        let blank = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        blank.insert(page, at: 0)
        for annotation in try #require(source.page(at: 0)).annotations {
            page.addAnnotation(try #require(annotation.copy() as? PDFAnnotation))
        }
        #expect(page.string == nil)
        #expect(String(decoding: try PDFConversion.exportData(document: blank, format: .text), as: UTF8.self).contains("LiveEditSentinel"))
        #expect(try !PDFOfficeExporter.spreadsheet(blank).isEmpty)
    }

    @Test("Fresh AI evidence includes live edits and fields with original page references")
    func assistantUsesEditedContent() async throws {
        let document = try fixture()
        let first = try await DocumentAssistantIndex.extract(from: document)
        #expect(first.retrieve("LiveEditSentinel").first?.pageNumber == 1)
        #expect(first.retrieve("FieldValueSentinel").first?.pageNumber == 1)
        #expect(first.retrieve("VisibleChoiceSentinel").first?.pageNumber == 1)
        #expect(first.retrieve("PasswordSentinel").isEmpty)
        let annotation = try #require(document.page(at: 0)?.annotations.first { $0.contents == "LiveEditSentinel" })
        annotation.contents = "UpdatedEvidenceSentinel"
        let refreshed = try await DocumentAssistantIndex.extract(from: document)
        #expect(refreshed.retrieve("UpdatedEvidenceSentinel").first?.pageNumber == 1)
        #expect(refreshed.retrieve("LiveEditSentinel").isEmpty)
        #expect(refreshed.coverageDescription.contains("not merged into paragraphs"))
    }

    private func fixture() throws -> PDFDocument {
        let document = try PDFConversion.textDocument(NSAttributedString(string: "BodySentinel", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)]))
        let page = try #require(document.page(at: 0))
        func box(_ value: String, y: Double) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds: CGRect(x: 50, y: y, width: 300, height: 30), forType: .freeText, withProperties: nil)
            annotation.contents = value
            annotation.font = .systemFont(ofSize: 14)
            page.addAnnotation(annotation)
            return annotation
        }
        // Deliberately reverse insertion order to exercise displayed reading order.
        _ = box("ForeignTextSentinel", y: 460)
        let live = box("LiveEditSentinel", y: 500)
        live.setValue("fixture-live", forAnnotationKey: PDFContentEditor.editIDKey)
        let hidden = box("HiddenSentinel", y: 550); hidden.shouldDisplay = false
        let badge = box("MarkerBadgeSentinel", y: 560)
        badge.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey)
        _ = box("OutsideSentinel", y: 9_000)
        let field = PDFAnnotation(bounds: CGRect(x: 50, y: 400, width: 300, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Name"; field.widgetStringValue = "FieldValueSentinel"
        page.addAnnotation(field)
        let choice = PDFAnnotation(bounds: CGRect(x: 50, y: 350, width: 300, height: 30), forType: .widget, withProperties: nil)
        choice.widgetFieldType = .choice; choice.fieldName = "Status"
        choice.choices = ["VisibleChoiceSentinel"]; choice.values = ["export-code"]; choice.widgetStringValue = "export-code"
        page.addAnnotation(choice)
        let password = PDFAnnotation(bounds: CGRect(x: 50, y: 300, width: 300, height: 30), forType: .widget, withProperties: nil)
        password.widgetFieldType = .text; password.fieldName = "Password"
        password.setValue(1 << 13, forAnnotationKey: .widgetFieldFlags)
        password.widgetStringValue = "PasswordSentinel"
        #expect(password.isPasswordField)
        page.addAnnotation(password)
        return document
    }
}
