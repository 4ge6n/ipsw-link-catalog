// Draws the app icon at every size macOS asks for, and the single square iOS
// asks for. iOS rounds and shadows the icon itself, so that one is drawn to the
// edges with none of the plate macOS wants around it.
// Run with: swift DrawIcon.swift <output directory> [ios]
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let outputDirectory = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

/// The rounded square macOS draws app icons in: a continuous curve, not a
/// circular corner, inset so it sits where every other icon sits.
func squirclePath(in rect: CGRect) -> CGPath {
    let radius = rect.width * 0.2237
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(size: CGFloat, fullBleed: Bool = false) -> CGImage {
    let side = Int(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // The art sits in the 824/1024 box Apple leaves for macOS icons; on iOS the
    // system supplies the shape, so it runs to the edges instead.
    let inset = fullBleed ? 0 : size * 0.1
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    context.saveGState()
    if fullBleed {
        context.addRect(plate)
    } else {
        context.addPath(squirclePath(in: plate))
    }
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.24, green: 0.53, blue: 0.99, alpha: 1),
        CGColor(srgbRed: 0.16, green: 0.31, blue: 0.86, alpha: 1),
        CGColor(srgbRed: 0.29, green: 0.20, blue: 0.75, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // A soft highlight across the top, the way Apple lights its icons.
    let sheen = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(sheen,
        startCenter: CGPoint(x: plate.midX, y: plate.maxY), startRadius: 0,
        endCenter: CGPoint(x: plate.midX, y: plate.maxY), endRadius: plate.width * 0.85,
        options: [])
    // The thin bright edge macOS icons carry where the light catches the rim.
    // There is no rim to catch it on iOS.
    if !fullBleed {
        context.setLineWidth(size * 0.006)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
        context.addPath(squirclePath(in: plate.insetBy(dx: size * 0.003, dy: size * 0.003)))
        context.strokePath()
    }
    context.restoreGState()

    // The glyph: an arrow coming down into a tray.
    let unit = plate.width
    let centre = CGPoint(x: plate.midX, y: plate.midY)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // The arrow lands above the tray's rim rather than through it.
    let shaftWidth = unit * 0.098
    let tip = CGPoint(x: centre.x, y: centre.y - unit * 0.055)
    let headHalf = unit * 0.185
    let headTop = tip.y + unit * 0.185
    let shaftTop = centre.y + unit * 0.335

    context.setLineWidth(shaftWidth)
    context.move(to: CGPoint(x: centre.x, y: shaftTop))
    context.addLine(to: CGPoint(x: centre.x, y: headTop + shaftWidth * 0.2))
    context.strokePath()

    context.setLineWidth(shaftWidth)
    context.move(to: CGPoint(x: centre.x - headHalf, y: headTop))
    context.addLine(to: tip)
    context.addLine(to: CGPoint(x: centre.x + headHalf, y: headTop))
    context.strokePath()

    // The tray it lands in, open at the top.
    let trayHalf = unit * 0.300
    let trayBottom = centre.y - unit * 0.320
    let trayShoulder = trayBottom + unit * 0.150
    context.setLineWidth(unit * 0.092)
    context.move(to: CGPoint(x: centre.x - trayHalf, y: trayShoulder))
    context.addLine(to: CGPoint(x: centre.x - trayHalf, y: trayBottom))
    context.addLine(to: CGPoint(x: centre.x + trayHalf, y: trayBottom))
    context.addLine(to: CGPoint(x: centre.x + trayHalf, y: trayShoulder))
    context.strokePath()

    return context.makeImage()!
}

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "ios" {
    let image = draw(size: 1024, fullBleed: true)
    let url = outputDirectory.appending(path: "AppIcon.png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("Wrote \(url.path)")
    exit(0)
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let image = draw(size: CGFloat(size))
    let url = outputDirectory.appending(path: "icon_\(size).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        continue
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(url.lastPathComponent)")
}
