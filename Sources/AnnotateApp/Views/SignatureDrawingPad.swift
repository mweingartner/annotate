import Atrium
import SwiftUI

/// A white pad to draw a signature with the pointer. Strokes are stored in unit
/// coordinates, so they scale to whatever area the signature is placed in.
struct SignatureDrawingPad: View {
    /// The pad's height; the image preview uses the same so the methods line up.
    static let height = Metrics.doubleRow * 3

    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []
    private let padHeight = SignatureDrawingPad.height

    var body: some View {
        Canvas { context, size in
            for stroke in strokes + [current] where !stroke.isEmpty {
                var path = Path()
                for (index, point) in stroke.enumerated() {
                    let scaled = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if index == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
                }
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: padHeight)
        // Paper stays white in dark mode: the ink is black, like the placed signature.
        .background(.white, in: .rect(cornerRadius: Radius.field))
        .overlay { RoundedRectangle(cornerRadius: Radius.field).strokeBorder(Palette.hairline) }
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            current.append(CGPoint(x: min(1, max(0, value.location.x / max(1, geometry.size.width))), y: min(1, max(0, value.location.y / padHeight))))
                        }
                        .onEnded { _ in
                            if current.count > 1 { strokes.append(current) }
                            current = []
                        })
            }
        }
        .accessibilityLabel("Signature drawing area")
        .accessibilityHint("Draw with the pointer. Choose Type for keyboard signature entry.")
    }
}
