import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { fatalError("No drawing context") }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    NSColor(calibratedRed: 0.08, green: 0.30, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 35, y: 35, width: 954, height: 954), xRadius: 220, yRadius: 220).fill()
    NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 234, y: 164, width: 556, height: 702), xRadius: 48, yRadius: 48).fill()
    let lines: [(CGFloat, CGFloat, NSColor)] = [
        (670, 355, NSColor(calibratedRed: 0.96, green: 0.77, blue: 0.25, alpha: 1)),
        (540, 292, NSColor(calibratedRed: 0.54, green: 0.76, blue: 0.69, alpha: 1)),
        (410, 338, NSColor(calibratedRed: 0.74, green: 0.65, blue: 0.86, alpha: 1))
    ]
    for (y, width, color) in lines {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 310, y: y, width: width, height: 51), xRadius: 13, yRadius: 13).fill()
    }
    NSColor(calibratedRed: 0.98, green: 0.54, blue: 0.35, alpha: 1).setFill()
    let bookmark = NSBezierPath()
    bookmark.move(to: NSPoint(x: 650, y: 876)); bookmark.line(to: NSPoint(x: 761, y: 876))
    bookmark.line(to: NSPoint(x: 761, y: 700)); bookmark.line(to: NSPoint(x: 705, y: 738))
    bookmark.line(to: NSPoint(x: 650, y: 700)); bookmark.close(); bookmark.fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    if [16, 32, 128, 256, 512].contains(pixels) {
        try png.write(to: output.appendingPathComponent("icon_\(pixels)x\(pixels).png"))
    }
    if [32, 64, 256, 512, 1024].contains(pixels) {
        try png.write(to: output.appendingPathComponent("icon_\(pixels/2)x\(pixels/2)@2x.png"))
    }
}
