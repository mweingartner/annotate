import AnnotateCore
import AppKit
import Atrium
import PDFKit
import SwiftUI
import Synchronization

@MainActor @objc(AnnotateDocument)
final class AnnotateDocument: NSDocument {
    let model = ReaderModel()
    nonisolated private let pendingData = Mutex<Data?>(nil)
    override var fileURL: URL? {
        didSet {
            if let name = fileURL?.lastPathComponent {
                Task { @MainActor [weak self] in self?.model.fileName = name }
            }
        }
    }
    override nonisolated class var autosavesInPlace: Bool { true }
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func changeCountToken(for saveOperation: NSDocument.SaveOperationType) -> Any {
        // NSDocument calls this on the main thread before taking a save snapshot.
        // Later live typing must have an inverse back to that exact checkpoint,
        // independent of delayed undo-group notifications or asynchronous writes.
        model.liveEdit?.needsUndoCheckpoint = true
        return super.changeCountToken(for: saveOperation)
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let document = PDFDocument(data: data), document.pageCount > 0 || document.isLocked else {
            throw NSError(domain: "Annotate", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file is not a readable PDF, or it has no pages."])
        }
        pendingData.withLock { $0 = data }
    }
    override func data(ofType typeName: String) throws -> Data {
        if model.hasPendingImageChanges {
            throw NSError(domain: "Annotate", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Apply or discard the pending image changes before saving the PDF."])
        }
        if model.liveEdit?.nativeUpdateFailed == true {
            throw NSError(domain: "Annotate", code: 4, userInfo: [NSLocalizedDescriptionKey:
                model.liveEdit?.nativeFailureMessage ?? "Resolve the pending text edit before saving the PDF."])
        }
        guard let document = model.pdfDocument, let data = document.dataRepresentation() else {
            throw NSError(domain: "Annotate", code: 2, userInfo: [NSLocalizedDescriptionKey: "The PDF could not be saved."])
        }
        return data
    }
    override func makeWindowControllers() {
        if model.pdfDocument == nil, let data = pendingData.withLock({ $0 }), let pdf = PDFDocument(data: data) {
            if pdf.isLocked {
                let alert = NSAlert()
                alert.messageText = "Unlock PDF"
                alert.informativeText = "Enter the password for \(displayName ?? "this PDF")."
                let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
                password.placeholderString = "Password"
                alert.accessoryView = password
                alert.addButton(withTitle: "Unlock")
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                guard response == .alertFirstButtonReturn, pdf.unlock(withPassword: password.stringValue) else {
                    if response == .alertFirstButtonReturn {
                        let failure = NSAlert(); failure.messageText = "The password did not unlock this PDF."; failure.runModal()
                    }
                    close(); return
                }
            }
            model.load(pdf, owner: self)
        }
        guard model.pdfDocument != nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = Metrics.mainWindow
        window.title = model.fileName
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        // SwiftUI supplies the glass toolbar; NSDocument keeps the title, proxy icon and
        // its "Edited" subtitle. The page position floats over the canvas instead.
        let host = NSHostingController(rootView: ReaderView(model: model))
        host.sceneBridgingOptions = [.toolbars]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1320, height: 860))
        window.center()
        window.setFrameAutosaveName("AnnotateReader")
        let controller = NSWindowController(window: window)
        addWindowController(controller)
    }
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let pdf = model.pdfDocument else { throw CocoaError(.fileReadUnknown) }
        guard pdf.allowsPrinting else {
            throw NSError(domain: "Annotate", code: 3, userInfo: [NSLocalizedDescriptionKey: "This PDF does not permit printing."])
        }
        let info = (printInfo.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.dictionary().addEntries(from: printSettings)
        guard let operation = pdf.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            throw NSError(domain: "Annotate", code: 3, userInfo: [NSLocalizedDescriptionKey: "This PDF does not permit printing."])
        }
        return operation
    }
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        if model.hasPendingImageChanges {
            let alert = NSAlert()
            alert.messageText = "Some image changes have not been applied"
            alert.informativeText = "Keep editing to apply the image replacement or frame changes. Discarding removes only these pending controls; earlier applied PDF edits remain."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard Unapplied Image Changes")
            if alert.runModal() == .alertSecondButtonReturn { model.discardImageChanges() }
            else {
                model.activeTool = .edit
                reportCloseCancelled(to: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
                return
            }
        }
        if model.liveEdit?.nativeUpdateFailed == true {
            let alert = NSAlert()
            alert.messageText = "Some text changes have not been applied"
            alert.informativeText = "Keep editing to correct the text or its size. Discarding removes only the unapplied editor contents; earlier applied PDF edits remain."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard Unapplied Text")
            if alert.runModal() == .alertSecondButtonReturn { model.discardPendingLiveText() }
            else {
                reportCloseCancelled(to: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
                return
            }
        }
        if model.hasDraftChanges {
            let alert = NSAlert()
            alert.messageText = "Save this marker before closing?"
            alert.informativeText = "Your annotation panel contains changes that have not been added to the PDF."
            alert.addButton(withTitle: "Save Marker")
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                model.saveDraft()
                if model.hasDraftChanges {
                    reportCloseCancelled(to: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
                    return
                }
            case .alertSecondButtonReturn: model.cancelDraft()
            default:
                reportCloseCancelled(to: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
                return
            }
        }
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    // NSDocument requires its three-argument Objective-C completion on cancellation
    // too, including during app termination. NSObject.perform cannot pass this ABI.
    func reportCloseCancelled(to delegate: Any, selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let receiver = delegate as? NSObject, let selector, receiver.responds(to: selector),
              let implementation = receiver.method(for: selector) else { return }
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(implementation, to: Callback.self)
        callback(receiver, selector, self, false, contextInfo)
    }
}
