import AppKit
import SwiftUI

@main
struct AnnotateApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindowController?
    private let welcomeModel = ReaderModel()
    var activeModel: ReaderModel? {
        (NSDocumentController.shared.currentDocument as? AnnotateDocument)?.model
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        NSDocumentController.shared.autosavingDelay = 10
        if NSDocumentController.shared.documents.isEmpty { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }
    @objc func showWelcome() {
        if let welcome { welcome.showWindow(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Annotate"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 600)
        window.contentViewController = NSHostingController(rootView: ReaderView(model: welcomeModel))
        window.center()
        welcome = NSWindowController(window: window)
        welcome?.showWindow(nil)
    }
    @objc func openSample() { welcomeModel.openSample() }
    @objc func newPDF() { welcomeModel.newBlankPDF() }
    @objc func convertFiles() {
        if let activeModel { activeModel.showTool(.convert) }
        else { showWelcome(); welcomeModel.activeTool = .convert }
    }
    @objc func editPDF() { activeModel?.showTool(.edit) }
    @objc func organizePages() { activeModel?.showTool(.pages) }
    @objc func fillForms() { activeModel?.showTool(.forms) }
    @objc func signPDF() { activeModel?.showTool(.sign) }
    @objc func redactPDF() { activeModel?.showTool(.redact) }
    @objc func documentAssistant() { activeModel?.showTool(.assistant) }
    @objc func find() { activeModel?.showSearch() }
    @objc func addMarker() { activeModel?.beginPageMarker() }
    @objc func nextMarker() { activeModel?.navigateMarker(1) }
    @objc func previousMarker() { activeModel?.navigateMarker(-1) }
    @objc func exportPDF() { activeModel?.exportDocument() }
    @objc func savePDF() { activeModel?.saveDocument() }
    @objc func zoomIn() { activeModel?.zoomIn() }
    @objc func zoomOut() { activeModel?.zoomOut() }
    @objc func fitPage() { activeModel?.fitPage() }
    @objc func toggleSidebar() { activeModel?.sidebarVisible.toggle() }
    @objc func allMarkers() { activeModel?.setFilter(.all) }
    @objc func importantMarkers() { activeModel?.setFilter(.important) }
    @objc func revisitMarkers() { activeModel?.setFilter(.revisit) }
    @objc func questionMarkers() { activeModel?.setFilter(.question) }
    @objc func noteMarkers() { activeModel?.setFilter(.note) }
    @objc func printPDF() { activeModel?.printDocument() }
    @objc func savePDFAs() {
        guard let model = activeModel else { return }
        if model.hasDraftChanges { model.saveDraft() }
        guard !model.hasDraftChanges else { return }
        model.owner?.saveAs(nil)
    }

    private func buildMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); bar.addItem(item)
            let submenu = NSMenu(title: title); item.submenu = submenu; return submenu
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ parent: NSMenu,
                  modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target; parent.addItem(item)
        }
        let app = menu("Annotate")
        item("About Annotate", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", app)
        app.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = NSMenu(title: "Services"); app.addItem(servicesItem); NSApp.servicesMenu = servicesItem.submenu
        item("Hide Annotate", #selector(NSApplication.hide(_:)), "h", app)
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", app, modifiers: [.command, .option])
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", app)
        app.addItem(.separator()); item("Quit Annotate", #selector(NSApplication.terminate(_:)), "q", app)
        let file = menu("File")
        item("New Blank PDF", #selector(newPDF), "n", file, target: self)
        item("Open PDF…", #selector(NSDocumentController.openDocument(_:)), "o", file, target: NSDocumentController.shared)
        item("Create, Convert & OCR…", #selector(convertFiles), "", file, target: self)
        item("Open Reading Guide", #selector(openSample), "", file, target: self)
        file.addItem(.separator())
        item("Close", #selector(NSWindow.performClose(_:)), "w", file)
        item("Save", #selector(savePDF), "s", file, target: self)
        item("Save As…", #selector(savePDFAs), "s", file, modifiers: [.command, .shift], target: self)
        item("Export Annotated PDF…", #selector(exportPDF), "e", file, modifiers: [.command, .shift], target: self)
        file.addItem(.separator()); item("Print…", #selector(printPDF), "p", file, target: self)
        let edit = menu("Edit")
        item("Undo", Selector(("undo:")), "z", edit)
        item("Redo", Selector(("redo:")), "z", edit, modifiers: [.command, .shift])
        edit.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), "x", edit)
        item("Copy", #selector(NSText.copy(_:)), "c", edit)
        item("Paste", #selector(NSText.paste(_:)), "v", edit)
        item("Select All", #selector(NSText.selectAll(_:)), "a", edit)
        edit.addItem(.separator()); item("Find in PDF…", #selector(find), "f", edit, target: self)
        let tools = menu("Tools")
        item("Edit PDF Text", #selector(editPDF), "e", tools, modifiers: [.command, .option], target: self)
        item("Organize Pages", #selector(organizePages), "", tools, target: self)
        item("Fill & Create Forms", #selector(fillForms), "", tools, target: self)
        item("Electronic Signatures", #selector(signPDF), "", tools, target: self)
        item("Convert, Compress & OCR", #selector(convertFiles), "", tools, target: self)
        item("Redact PDF", #selector(redactPDF), "", tools, target: self)
        item("Document Assistant", #selector(documentAssistant), "j", tools, modifiers: [.command, .option], target: self)
        let view = menu("View")
        item("Toggle Marker Panel", #selector(toggleSidebar), "s", view, modifiers: [.command, .option], target: self)
        item("All Markers", #selector(allMarkers), "", view, target: self)
        item("Important Passages", #selector(importantMarkers), "", view, target: self)
        item("Revisit List", #selector(revisitMarkers), "", view, target: self)
        item("Questions", #selector(questionMarkers), "", view, target: self)
        item("Notes", #selector(noteMarkers), "", view, target: self)
        view.addItem(.separator())
        item("Zoom In", #selector(zoomIn), "+", view, target: self)
        item("Zoom Out", #selector(zoomOut), "-", view, target: self)
        item("Fit Width", #selector(fitPage), "0", view, target: self)
        let marks = menu("Markers")
        item("Mark Current Location", #selector(addMarker), "m", marks, modifiers: [.command, .shift], target: self)
        item("Next Marker", #selector(nextMarker), "]", marks, modifiers: [.command, .option], target: self)
        item("Previous Marker", #selector(previousMarker), "[", marks, modifiers: [.command, .option], target: self)
        let window = menu("Window"); NSApp.windowsMenu = window
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", window)
        item("Zoom", #selector(NSWindow.performZoom(_:)), "", window)
        item("Welcome to Annotate", #selector(showWelcome), "", window, target: self)
        NSApp.mainMenu = bar
    }
}
