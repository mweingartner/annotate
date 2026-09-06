import Foundation

public enum DocumentAssistantError: Error, LocalizedError, Equatable {
    case copyingRestricted
    case noText
    case noSelection
    case noQuestion
    case noMatches
    case documentTooLarge
    case requestTooLong
    case contextTooLarge
    case unavailable(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .copyingRestricted: "This PDF restricts copying or is locked. The assistant cannot extract its text."
        case .noText: "No selectable text was found. Run OCR on scanned pages, then try the assistant again."
        case .noSelection: "Select a passage in the PDF first, then choose Explain selection or Translate selection."
        case .noQuestion: "Enter a question or words to find in the document."
        case .noMatches: "No passages matched those words. Try a distinctive name, phrase, or topic from the PDF."
        case .documentTooLarge: "This document exceeds the assistant limit of 10,000 pages or 8 MB of extracted text. Extract a smaller page range first. No partial answer was generated."
        case .requestTooLong: "Use a question of at most 1,000 UTF-8 bytes or a selection of at most 4,000 UTF-8 bytes. No text was silently shortened."
        case .contextTooLarge: "This text exceeds the local model's context limit. Select a shorter passage or ask a more specific question. No partial answer was presented."
        case .unavailable(let reason): reason
        case .generationFailed(let reason): "The model could not finish: \(reason). Source passages remain available below."
        }
    }
}
