import Foundation

public enum PDFFormError: LocalizedError {
    case invalidName, duplicateName, invalidChoices, invalidRadioValue, invalidBounds, creationRestricted, fillingRestricted, readOnly, tooLong
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Use a field name of 1–255 bytes without periods."
        case .duplicateName: "Choose a unique field name. Radio buttons may share a group name with different option values."
        case .invalidChoices: "Provide distinct, nonempty dropdown choices and select one of those choices."
        case .invalidRadioValue: "Choose a distinct radio option value other than Off."
        case .invalidBounds: "Place the field entirely within the page, at least 4 points wide and high."
        case .creationRestricted: "This PDF does not permit creating or removing form fields."
        case .fillingRestricted: "This PDF does not permit filling its form fields."
        case .readOnly: "This field is read-only or is no longer available."
        case .tooLong: "This value exceeds the field’s maximum length."
        }
    }
}
