import AnnotateCore
import Atrium
import SwiftUI

/// A marker's face: its symbol on its colour, in the continuous-corner shape of a Mac
/// icon. The same glyph appears in the sidebar, the details popover and on the page, so
/// a marker is recognisable wherever it shows up.
struct MarkerGlyph: View {
    let symbol: String
    let color: Color
    let ink: Color
    var size: CGFloat = Metrics.minimumControl

    init(symbol: String, color: MarkerColor, size: CGFloat = Metrics.minimumControl) {
        self.symbol = symbol
        self.color = Color(nsColor: color.nsColor)
        self.ink = Color(nsColor: color.readableInkColor)
        self.size = size
    }

    init(marker: PDFMarker, size: CGFloat = Metrics.minimumControl) {
        self.init(symbol: marker.icon, color: marker.color, size: size)
    }

    /// Corner radius as a share of the side, shared with the pins on the page.
    static let cornerRatio = MarkerPinArtwork.cornerRatio

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * MarkerPinArtwork.symbolPointScale, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background {
                // The pin's colour body and sheen, without the glass and lift that only
                // make sense floating over a page.
                shape.fill(color.gradient)
                    .overlay {
                        shape.fill(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0)],
                                                  startPoint: .top, endPoint: .center))
                    }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.12)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
