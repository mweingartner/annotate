import Foundation

public enum PDFFormKind: String, CaseIterable, Identifiable, Sendable {
    case text, checkbox, radio, choice, list
    public var id: Self { self }
    public var title: String {
        switch self {
        case .text: "Text field"
        case .checkbox: "Checkbox"
        case .radio: "Radio button"
        case .choice: "Dropdown"
        case .list: "List box"
        }
    }
}
