#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: generate_app_icon.swift SOURCE.png OUTPUT.icns\n".utf8)
    )
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("Could not read source image.\n".utf8))
    exit(1)
}

let representations: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1_024)
]

func pngData(pixels: Int) -> Data? {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
        in: NSRect(origin: .zero, size: size),
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1
    )
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}

func bigEndianData(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
}

var body = Data()
for representation in representations {
    guard let png = pngData(pixels: representation.pixels) else {
        FileHandle.standardError.write(
            Data("Could not render \(representation.pixels)-pixel icon.\n".utf8)
        )
        exit(1)
    }
    body.append(Data(representation.type.utf8))
    body.append(bigEndianData(UInt32(png.count + 8)))
    body.append(png)
}

var output = Data("icns".utf8)
output.append(bigEndianData(UInt32(body.count + 8)))
output.append(body)
try output.write(to: outputURL, options: .atomic)
