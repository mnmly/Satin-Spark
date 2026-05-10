import CoreGraphics
import Foundation
import ImageIO

struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fputs("usage: satin-spark-image-diff <actual.png> <reference.png> [diff.png]\n", stderr)
    exit(2)
}

let actualURL = URL(fileURLWithPath: arguments[0])
let referenceURL = URL(fileURLWithPath: arguments[1])
let diffURL = arguments.dropFirst(2).first.map(URL.init(fileURLWithPath:))

do {
    let actual = try loadRGBAImage(actualURL)
    let reference = try loadRGBAImage(referenceURL)
    guard actual.width == reference.width, actual.height == reference.height else {
        throw RuntimeError("image sizes differ: actual=\(actual.width)x\(actual.height) reference=\(reference.width)x\(reference.height)")
    }

    var diffPixels = [UInt8](repeating: 0, count: actual.pixels.count)
    var totalAbsoluteDifference = 0
    var maxChannelDifference = 0
    var changedPixelCount = 0
    var changedPixelCountThreshold8 = 0

    for pixelIndex in 0 ..< actual.width * actual.height {
        let base = pixelIndex * 4
        var pixelDifference = 0
        for channel in 0 ..< 4 {
            let difference = abs(Int(actual.pixels[base + channel]) - Int(reference.pixels[base + channel]))
            pixelDifference += difference
            totalAbsoluteDifference += difference
            maxChannelDifference = max(maxChannelDifference, difference)
            diffPixels[base + channel] = UInt8(min(255, difference * 8))
        }
        diffPixels[base + 3] = 255
        if pixelDifference > 0 {
            changedPixelCount += 1
        }
        if pixelDifference > 8 {
            changedPixelCountThreshold8 += 1
        }
    }

    let pixelCount = actual.width * actual.height
    let channelCount = pixelCount * 4
    let mae = Double(totalAbsoluteDifference) / Double(channelCount)
    let normalizedMAE = mae / 255.0
    let changedRatio = Double(changedPixelCount) / Double(pixelCount)
    let changedRatioThreshold8 = Double(changedPixelCountThreshold8) / Double(pixelCount)

    print("size=\(actual.width)x\(actual.height)")
    print("mae=\(String(format: "%.6f", mae))")
    print("normalizedMAE=\(String(format: "%.8f", normalizedMAE))")
    print("maxChannelDifference=\(maxChannelDifference)")
    print("changedPixelRatio=\(String(format: "%.8f", changedRatio))")
    print("changedPixelRatioThreshold8=\(String(format: "%.8f", changedRatioThreshold8))")

    if let diffURL {
        try FileManager.default.createDirectory(at: diffURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(RGBAImage(width: actual.width, height: actual.height, pixels: diffPixels), to: diffURL)
        print("wroteDiff=\(diffURL.path)")
    }
} catch {
    fputs("satin-spark-image-diff: \(error)\n", stderr)
    exit(1)
}

func loadRGBAImage(_ url: URL) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw RuntimeError("failed to decode \(url.path)")
    }

    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw RuntimeError("failed to create bitmap context")
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RGBAImage(width: width, height: height, pixels: pixels)
}

func writePNG(_ image: RGBAImage, to url: URL) throws {
    let bytesPerRow = image.width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
          let cgImage = CGImage(
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else {
        throw RuntimeError("failed to create PNG destination")
    }

    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RuntimeError("failed to write \(url.path)")
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
