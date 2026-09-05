import AnnotateCore
import Observation
import SwiftUI

@MainActor @Observable
final class MarkerDraft {
    var id: UUID
    var categories: Set<MarkerCategory>
    var color: Color
    var icon: String
    var quote: String
    var note: String
    var question: String
    var regions: [PageRegion]
    var isEditing: Bool

    init(id: UUID = UUID(), categories: Set<MarkerCategory> = [.important], color: Color = .yellow,
         icon: String = "star.fill", quote: String, note: String = "", question: String = "",
         regions: [PageRegion], isEditing: Bool = false) {
        self.id = id; self.categories = categories; self.color = color; self.icon = icon
        self.quote = quote; self.note = note; self.question = question; self.regions = regions
        self.isEditing = isEditing
    }
}
