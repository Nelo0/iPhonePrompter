// Draws a simple 1024×1024 app icon: dark rounded square, white prompt lines, a lens dot.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 40, y: 40, width: size - 80, height: size - 80)
NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190).fill()
NSColor.white.withAlphaComponent(0.35).setFill()
NSBezierPath(roundedRect: NSRect(x: 200, y: 660, width: 560, height: 56), xRadius: 28, yRadius: 28).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 200, y: 540, width: 624, height: 70), xRadius: 35, yRadius: 35).fill()
NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.24, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 170, y: 210, width: 684, height: 260), xRadius: 60, yRadius: 60).fill()
NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.45, alpha: 1).setStroke()
let lens = NSBezierPath(ovalIn: NSRect(x: 240, y: 330, width: 110, height: 110)); lens.lineWidth = 22; lens.stroke()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
