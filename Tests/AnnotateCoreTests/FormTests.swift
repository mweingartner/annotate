import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Interactive PDF forms", .serialized)
@MainActor
struct FormTests {
    private func region(_ index: Int = 0) -> PageRegion {
        PageRegion(pageIndex: 0, bounds: CGRect(x: 80, y: 80 + index * 40, width: 150, height: 30))
    }

    @Test("Text, checkbox, and choice field values persist in a reopened PDF")
    func persistence() throws {
        let document = try Fixtures.document()
        try PDFFormEditor.create(in: document, region: region(), name: "Name", kind: .text, multiline: true)
        try PDFFormEditor.create(in: document, region: region(1), name: "Agree", kind: .checkbox)
        try PDFFormEditor.create(in: document, region: region(2), name: "Color", kind: .choice, choices: ["Red", "Blue"])
        for field in PDFFormEditor.fields(in: document) {
            try PDFFormEditor.fill(in: document, field: field, value: field.kind == .text ? "Émilie 日本語" : field.kind == .checkbox ? "Yes" : "Blue")
        }
        let fields = PDFFormEditor.fields(in: try Fixtures.reopen(document))
        #expect(fields.count == 3)
        #expect(fields.first { $0.name == "Name" }?.value == "Émilie 日本語")
        #expect(fields.first { $0.name == "Agree" }?.checked == true)
        #expect(fields.first { $0.name == "Color" }?.value == "Blue")
    }

    @Test("Radio group options are exclusive and persist independently")
    func radioGroup() throws {
        let document = try Fixtures.document()
        try PDFFormEditor.create(in: document, region: region(), name: "Size", kind: .radio, exportValue: "Small")
        try PDFFormEditor.create(in: document, region: region(1), name: "Size", kind: .radio, exportValue: "Large")
        let first = try #require(PDFFormEditor.fields(in: document).first)
        try PDFFormEditor.fill(in: document, field: first, value: "Small")
        let second = try #require(PDFFormEditor.fields(in: document).last)
        try PDFFormEditor.fill(in: document, field: second, value: "Large")
        let fields = PDFFormEditor.fields(in: try Fixtures.reopen(document))
        #expect(fields.count == 2)
        #expect(fields.filter(\.checked).count == 1)
        #expect(fields.first(where: \.checked)?.exportValue == "Large")
    }

    @Test("List boxes retain their widget type and selected value after reopening")
    func listBoxPersistence() throws {
        let document = try Fixtures.document()
        let options = ["English", "Español", "日本語"]
        try PDFFormEditor.create(in: document, region: region(), name: "Language", kind: .list, choices: options)
        let initial = try #require(PDFFormEditor.fields(in: document).first)
        #expect(initial.kind == .list)
        try PDFFormEditor.fill(in: document, field: initial, value: "日本語")
        #expect(throws: (any Error).self) { try PDFFormEditor.fill(in: document, field: initial, value: "Missing") }
        let reopened = try Fixtures.reopen(document)
        let restored = try #require(PDFFormEditor.fields(in: reopened).first)
        #expect(restored.kind == .list)
        #expect(restored.choices == options)
        #expect(restored.value == "日本語")
        #expect(reopened.page(at: 0)?.annotations.first?.isListChoice == true)
    }

    @Test("Duplicate names, out-of-page regions, and invalid choices are rejected")
    func invalidCreation() throws {
        let document = try Fixtures.document()
        try PDFFormEditor.create(in: document, region: region(), name: "Name", kind: .text)
        #expect(throws: (any Error).self) { try PDFFormEditor.create(in: document, region: region(1), name: "Name", kind: .text) }
        #expect(throws: (any Error).self) { try PDFFormEditor.create(in: document, region: region(1), name: "Options", kind: .choice, choices: []) }
        #expect(throws: (any Error).self) { try PDFFormEditor.create(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: -20, y: -10, width: 20, height: 20)), name: "Outside", kind: .text) }
        #expect(PDFFormEditor.fields(in: document).count == 1)
    }

    @Test("Read-only and maximum-length fields are protected")
    func constraints() throws {
        let document = try Fixtures.document()
        try PDFFormEditor.create(in: document, region: region(), name: "Name", kind: .text)
        let annotation = try #require(document.page(at: 0)?.annotations.first)
        let field = try #require(PDFFormEditor.fields(in: document).first)
        annotation.maximumLength = 3
        #expect(throws: (any Error).self) { try PDFFormEditor.fill(in: document, field: field, value: "long") }
        annotation.isReadOnly = true
        #expect(throws: (any Error).self) { try PDFFormEditor.fill(in: document, field: field, value: "Ada") }
        #expect(annotation.widgetStringValue == "")
    }
}
