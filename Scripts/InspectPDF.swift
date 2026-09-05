import Foundation
import PDFKit

for path in CommandLine.arguments.dropFirst() {
    guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else {
        fputs("Cannot read PDF: \(path)\n", stderr)
        exit(1)
    }
    var annotationCount = 0
    var markerIDs = Set<String>()
    for index in 0..<pdf.pageCount {
        guard let page = pdf.page(at: index) else { continue }
        annotationCount += page.annotations.count
        for annotation in page.annotations {
            if let identifier = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/AnnotateMarkerID")) as? String {
                markerIDs.insert(identifier)
            }
        }
    }
    let text = pdf.string ?? ""
    print("\(URL(fileURLWithPath: path).lastPathComponent): \(pdf.pageCount) pages; \(annotationCount) annotations; \(markerIDs.count) marker IDs; \(text.count) text characters")
    print("Contains note: \(text.contains("Review this passage against the original source.")); contains question: \(text.contains("What evidence would change this conclusion?"))")
}
