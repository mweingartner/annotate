import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Assistant reader integration")
@MainActor
struct AssistantSelectionTests {
    @Test("A selection spanning pages preserves original text and distinct source pages")
    func multiplePages() throws {
        let document = SamplePDF.make()
        let model = ReaderModel()
        model.pdfDocument = document
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 700))
        view.document = document
        model.pdfView = view
        let firstPage = try #require(document.page(at: 0))
        let secondPage = try #require(document.page(at: 1))
        let first = try #require(firstPage.selection(for: NSRange(location: 0, length: 35)))
        let second = try #require(secondPage.selection(for: NSRange(location: 0, length: 35)))
        first.add(second)
        view.setCurrentSelection(first, animate: false)
        let sources = try model.assistantSelection()
        #expect(sources.map(\.pageNumber) == [1, 2])
        #expect(sources.allSatisfy { !$0.text.isEmpty })
        #expect(sources.first?.text.localizedCaseInsensitiveContains("read with intention") == true)
        #expect(Set(sources.map(\.id)).count == sources.count)
    }

    @Test("A stale selection from another PDF is not used as current evidence")
    func staleSelection() throws {
        let oldDocument = SamplePDF.make()
        let model = ReaderModel()
        model.pdfDocument = SamplePDF.make()
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 700))
        view.document = oldDocument
        model.pdfView = view
        let page = try #require(oldDocument.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: 35)))
        view.setCurrentSelection(selection, animate: false)
        #expect(try model.assistantSelection().isEmpty)
    }

    @Test("Provider preferences persist only nonsecret configuration")
    func preferences() throws {
        let suite = "annotate-assistant-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DocumentAssistantPreferences(defaults: defaults)
        #expect(first.provider == .ollama)
        first.provider = .claude
        first.claudeModel = "chosen-model"
        first.claudeWorkspaceID = "chosen-workspace"
        let second = DocumentAssistantPreferences(defaults: defaults)
        #expect(second.provider == .claude)
        #expect(second.claudeModel == "chosen-model")
        #expect(second.claudeWorkspaceID == "chosen-workspace")
        #expect(defaults.string(forKey: "assistant.apiKey") == nil)
    }
}
