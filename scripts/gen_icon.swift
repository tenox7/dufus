import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconsetPath = "\(outDir)/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func tintedSymbol(_ name: String, size: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.45, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

for (name, px) in entries {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    let inset = s * 0.10
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let r = s * 0.22
    let bg = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    NSGradient(
        starting: NSColor(red: 0.22, green: 0.52, blue: 0.96, alpha: 1),
        ending: NSColor(red: 0.14, green: 0.38, blue: 0.88, alpha: 1)
    )?.draw(in: bg, angle: -90)

    if let symbol = tintedSymbol("arrow.down.doc.fill", size: s) {
        let x = (s - symbol.size.width) / 2
        let y = (s - symbol.size.height) / 2
        symbol.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name).png"))
}

let icnsPath = "\(outDir)/AppIcon.icns"
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", icnsPath, iconsetPath]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(atPath: iconsetPath)
print("Created \(icnsPath)")
