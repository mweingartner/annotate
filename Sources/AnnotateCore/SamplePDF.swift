import AppKit
import CoreText
import PDFKit

/// A local, text-selectable tour. Opening it never adds or saves annotations.
@MainActor
public enum SamplePDF {
    public static func make() -> PDFDocument {
        let data = NSMutableData()
        var pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
            return PDFDocument()
        }

        let pages: [(String, String, [(String, String)])] = [
            ("READ WITH INTENTION", "A place for your attention", [
                ("A better way to return", "Some ideas deserve more than a bookmark. Annotate lets you attach meaning to an exact passage: something important, a thought to revisit, a question to investigate, or a note in your own words."),
                ("Try your first marker", "Select a few words in this paragraph. A panel opens with your selection. Choose Important, Revisit, Question, or Note; combine categories when it helps. Add a note or a question, choose a color and an icon, then save your marker."),
                ("Attention is a choice", "When a passage catches your attention, ask what made it stand out. Is it evidence, an unfamiliar idea, or a useful next step? A short note can preserve the reason you stopped, so returning later feels useful."),
                ("A question worth keeping", "What would change my mind about this idea? Select this question and mark it as Question. You can also mark it Important and write a note about the evidence you want to find.")
            ]),
            ("BUILD A READING TRAIL", "Turn highlights into action", [
                ("Keep categories useful", "Important passages are the ideas you want to remember. Revisit marks are promises to come back. Questions capture uncertainty. Notes keep your interpretation close to the source. One passage can belong to several categories."),
                ("Make the mark yours", "Choose a preset color or open the color picker for your own palette. An icon makes a marker easier to recognize. Color can represent a topic, an author, or a level of confidence; it does not need to duplicate the category."),
                ("Practice a longer selection", "This paragraph spans several lines, giving you a place to try a longer highlight. Pay attention to how each line is marked independently. Your selected text should remain readable, and your note should stay attached to the complete passage."),
                ("Return without losing context", "Open the marker sidebar and click a saved entry. Annotate takes you back to the passage. Use the category filters to focus on important ideas, items to revisit, questions, or notes. Move to the next or previous marker as you review.")
            ]),
            ("FIND WHAT YOU NEED", "Search in context", [
                ("Try a search", "Open Search and look for attention. The search panel lists each match with surrounding words and its page number. Click a result to jump to that exact location. Searching helps you compare passages before deciding which ones deserve a marker."),
                ("Read around the match", "A word alone is rarely enough. The context around attention may describe a choice, a habit, or a limited resource. Read the surrounding sentence before treating two matches as evidence for the same claim."),
                ("Ask a specific question", "Instead of writing only 'check this', name what you want to learn. For example: Does the next section provide evidence for this claim? A specific question makes the next reading session easier to begin."),
                ("Save your working copy", "Save the document to keep editable markers, categories, notes, and questions inside the PDF. Reopen that saved PDF in Annotate to continue your work. Other PDF readers can display the standard highlights and note icons.")
            ]),
            ("SHARE WHAT MATTERS", "Take your reading with you", [
                ("An editable original", "Your saved working PDF preserves the markers that Annotate uses for navigation and editing. Keep this copy when you want to continue reading and refine your notes later."),
                ("A shareable export", "Export a flattened PDF to bake the visible highlights and icons into the pages. When you include notes, the export adds a readable index with page references, selected passages, notes, and questions. The exported marks are part of the page content."),
                ("Print and review", "Use Print to choose a printer or the macOS PDF options. Review the document in the print preview before sending it to a printer. To print the notes index as well, open and print your exported PDF."),
                ("A small review ritual", "Give your attention to the Revisit list first. Answer one question, improve one note, and remove a marker that no longer helps. A reading trail stays useful when it reflects what you still need to understand.")
            ])
        ]

        for (index, page) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(pageRect)
            context.setFillColor(NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.45, alpha: 1).cgColor)
            context.fill(CGRect(x: 50, y: 716, width: 36, height: 4))
            draw(page.0, at: CGPoint(x: 50, y: 695), size: 10, weight: .semibold, color: .gray, context: context)
            draw(page.1, at: CGPoint(x: 50, y: 652), size: 27, weight: .bold, context: context)
            var top: CGFloat = 606
            for section in page.2 {
                draw(section.0, at: CGPoint(x: 50, y: top), size: 14, weight: .semibold, context: context)
                top -= 17
                let attributed = NSAttributedString(string: section.1, attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1),
                    .paragraphStyle: paragraphStyle()
                ])
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                    CGSize(width: 512, height: CGFloat.greatestFiniteMagnitude), nil)
                let height = ceil(suggested.height) + 5
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(),
                    CGPath(rect: CGRect(x: 50, y: top - height, width: 512, height: height), transform: nil), nil)
                CTFrameDraw(frame, context)
                top -= height + 29
            }
            context.setStrokeColor(NSColor(calibratedWhite: 0.86, alpha: 1).cgColor)
            context.move(to: CGPoint(x: 50, y: 52))
            context.addLine(to: CGPoint(x: 562, y: 52))
            context.strokePath()
            draw("ANNOTATE  /  A READING TOUR", at: CGPoint(x: 50, y: 34), size: 9, color: .gray, context: context)
            draw("\(index + 1) / \(pages.count)", at: CGPoint(x: 538, y: 34), size: 9, color: .gray, context: context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFDocument(data: data as Data) ?? PDFDocument()
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Annotate — A Reading Tour", PDFDocumentAttribute.authorAttribute: "Annotate"]
        return document
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }

    private static func draw(_ string: String, at point: CGPoint, size: CGFloat,
                             weight: NSFont.Weight = .regular, color: NSColor = .black,
                             context: CGContext) {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color.usingColorSpace(.deviceRGB) ?? NSColor.black
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}
