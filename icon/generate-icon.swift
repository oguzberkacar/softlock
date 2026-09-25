import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Transparent canvas, navy rounded square (macOS icon grid: 824 in 1024).
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 185
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Subtle vertical navy gradient for depth.
let top = NSColor(red: 0.10, green: 0.14, blue: 0.32, alpha: 1)     // lighter navy
let bottom = NSColor(red: 0.05, green: 0.07, blue: 0.20, alpha: 1)  // deep navy
let gradient = NSGradient(starting: top, ending: bottom)!
gradient.draw(in: bg, angle: -90)

// Yellow lock, centered.
let yellow = NSColor(red: 1.0, green: 0.80, blue: 0.08, alpha: 1.0)
let config = NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    yellow.set()
    let symRect = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: symRect)
    symRect.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let drawRect = NSRect(
        x: (size - tinted.size.width) / 2,
        y: (size - tinted.size.height) / 2,
        width: tinted.size.width,
        height: tinted.size.height
    )
    tinted.draw(in: drawRect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render icon PNG")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
