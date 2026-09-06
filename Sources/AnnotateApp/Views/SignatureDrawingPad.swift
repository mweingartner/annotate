import SwiftUI

struct SignatureDrawingPad: View {
    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []
    private let padHeight = 130.0

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
        .background(.white, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.4)) }
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
