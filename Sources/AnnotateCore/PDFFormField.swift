import Foundation

public struct PDFFormField: Identifiable, Equatable {
    public var id: String { "\(pageIndex):\(annotationIndex)" }
    public let pageIndex: Int
    public let annotationIndex: Int
    public let name: String
    public let kind: PDFFormKind
    public let value: String
    public let choices: [String]
    public let readOnly: Bool
    public let checked: Bool
    public let exportValue: String
}
