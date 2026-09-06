import Foundation

enum SignatureMethod: String, CaseIterable, Identifiable {
    case type = "Type", draw = "Draw", image = "Image"
    var id: Self { self }
}
