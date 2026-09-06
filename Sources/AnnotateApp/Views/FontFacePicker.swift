import SwiftUI

struct FontFacePicker: View {
    @Bindable var session: LiveTextEdit

    var body: some View {
        Picker("Typeface", selection: $session.fontName) {
            ForEach(faces) { face in Text(face.title).tag(face.name) }
            if !faces.contains(where: { $0.name == session.fontName }) {
                Text(session.font.displayName ?? session.fontName).tag(session.fontName)
            }
        }
        .accessibilityLabel("Font typeface")
    }
    private var faces: [FontFace] { FontCatalog.faces(in: FontCatalog.family(of: session.font)) }
}
