// Draws the app icon (a green tile holding a white sheet) as a 1024 px PNG: `swift make_icon.swift out.png`.
import AppKit

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x3CCB82), ending: color(0x1C9150))!.draw(in: tile, angle: -90)

let sheet = NSRect(x: 222, y: 232, width: 580, height: 560)
let row: CGFloat = 112
NSColor.white.setFill()
let card = NSBezierPath(roundedRect: sheet, xRadius: 44, yRadius: 44)
card.fill()
card.addClip()
color(0xC4EBD3).setFill()
NSRect(x: sheet.minX, y: sheet.maxY - row, width: sheet.width, height: row).fill()
color(0xCFE9DA).setFill()
for line in 1...4 { NSRect(x: sheet.minX, y: sheet.maxY - row * CGFloat(line) - 4, width: sheet.width, height: 8).fill() }
for line in 1...2 { NSRect(x: sheet.minX + sheet.width * CGFloat(line) / 3 - 4, y: sheet.minY, width: 8, height: sheet.height).fill() }

try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
