import CoreGraphics
import Foundation
import ImageIO
import Metal
import Satin
import SatinSpark
import UniformTypeIdentifiers

struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

struct RenderFixtureResult {
    var image: RGBAImage
    var modelViewMatrix: simd_float4x4
    var projectionMatrix: simd_float4x4
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/satin-spark-fixture.png")
let size = SIMD2<Int>(512, 512)
let clearColor = SIMD4<Float>(0.03, 0.035, 0.045, 1.0)

do {
    let result = try renderFixture(size: size, clearColor: clearColor)
    let image = result.image
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePNG(image, to: outputURL)
    let coverage = contentCoverage(image, clearColor: clearColor)
    guard coverage.changedPixelRatio > 0.002 else {
        throw RuntimeError("Rendered image appears empty: changedPixelRatio=\(coverage.changedPixelRatio)")
    }
    if ProcessInfo.processInfo.environment["SATIN_SPARK_VERIFY_PROJECTED_SAMPLES"] == "1" {
        try verifyProjectedSamples(
            image,
            modelViewMatrix: result.modelViewMatrix,
            projectionMatrix: result.projectionMatrix
        )
    }
    if ProcessInfo.processInfo.environment["SATIN_SPARK_VERIFY_ALPHA_FALLOFF"] == "1" {
        try verifyAlphaFalloff(size: size, clearColor: clearColor)
    }
    print("wrote \(outputURL.path)")
    print("changedPixelRatio=\(coverage.changedPixelRatio)")
    print("meanNormalizedDifference=\(coverage.meanNormalizedDifference)")
} catch {
    fputs("satin-spark-render-fixture: \(error)\n", stderr)
    exit(1)
}

func renderFixture(
    size: SIMD2<Int>,
    clearColor: SIMD4<Float>,
    packedSplats: PackedSplats = SplatFixtures.deterministicScene()
) throws -> RenderFixtureResult {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw RuntimeError("Metal is unavailable")
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw RuntimeError("Failed to create command queue")
    }

    let context = Context(
        device: device,
        sampleCount: 1,
        colorPixelFormat: .bgra8Unorm,
        depthPixelFormat: .depth32Float
    )
    let renderer = Renderer(context: context, clearColor: clearColor)
    renderer.resize((width: Float(size.x), height: Float(size.y)))

    let fixtureSplats = packedSplats
    if ProcessInfo.processInfo.environment["SATIN_SPARK_DUMP_PACKED"] == "1" {
        for index in 0 ..< fixtureSplats.numSplats {
            let offset = index * 4
            print(
                "packed[\(index)]",
                String(fixtureSplats.packedArray[offset + 0], radix: 16),
                String(fixtureSplats.packedArray[offset + 1], radix: 16),
                String(fixtureSplats.packedArray[offset + 2], radix: 16),
                String(fixtureSplats.packedArray[offset + 3], radix: 16)
            )
        }
    }
    let splatMesh = SplatMesh(context: context, packedSplats: fixtureSplats)
    let scene = Object(context: context, label: "SatinSpark Fixture", [splatMesh])
    let camera = PerspectiveCamera(context: context, position: [0.0, 0.0, 3.2], near: 0.01, far: 100.0, fov: 45.0)
    camera.aspect = Float(size.x) / Float(size.y)
    camera.lookAt(target: .zero)
    if ProcessInfo.processInfo.environment["SATIN_SPARK_DUMP_REFERENCE"] == "1" {
        for index in 0 ..< fixtureSplats.numSplats {
            let decoded = SplatReference.decodePackedSplat(
                fixtureSplats.packedWords(at: index),
                encoding: fixtureSplats.splatEncoding
            )
            let projected = SplatReference.project(
                decoded,
                modelViewMatrix: camera.viewMatrix,
                projectionMatrix: camera.projectionMatrix,
                renderSize: [Float(size.x), Float(size.y)]
            )
            if let projected {
                print(
                    "reference[\(index)]",
                    "center=\(decoded.center)",
                    "scales=\(decoded.scales)",
                    "viewZ=\(projected.viewCenter.z)",
                    "radii=\(projected.radius1),\(projected.radius2)",
                    "rgba=\(projected.rgba)"
                )
            } else {
                print("reference[\(index)] culled")
            }
        }
    }
    splatMesh.setup()
    guard let material = splatMesh.material as? SplatMaterial else {
        throw RuntimeError("Splat mesh material is not SplatMaterial")
    }
    material.renderSize = [Float(size.x), Float(size.y)]
    if ProcessInfo.processInfo.environment["SATIN_SPARK_DEBUG_QUADS"] == "1" {
        material.debugMode = 1
    } else if ProcessInfo.processInfo.environment["SATIN_SPARK_DEBUG_PROJECTED"] == "1" {
        material.debugMode = 2
    } else if ProcessInfo.processInfo.environment["SATIN_SPARK_DEBUG_COVARIANCE"] == "1" {
        material.debugMode = 3
    } else if ProcessInfo.processInfo.environment["SATIN_SPARK_DEBUG_SCALES"] == "1" {
        material.debugMode = 4
    }
    material.update()
    if ProcessInfo.processInfo.environment["SATIN_SPARK_DUMP_MATERIAL_PARAMS"] == "1" {
        print(material.parameters.debugDescription)
    }
    guard material.getPipeline(renderContext: context, shadow: false) != nil else {
        throw RuntimeError("Splat material pipeline was not created")
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: size.x,
        height: size.y,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    let storageMode = readableTextureStorageMode()
    descriptor.storageMode = storageMode

    guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
        throw RuntimeError("Failed to create output texture")
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw RuntimeError("Failed to create command buffer")
    }

    renderer.draw(
        renderPassDescriptor: MTLRenderPassDescriptor(),
        commandBuffer: commandBuffer,
        scene: scene,
        camera: camera,
        renderTarget: outputTexture
    )

    if storageMode == .managed, let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
        blitEncoder.synchronize(resource: outputTexture)
        blitEncoder.endEncoding()
    }

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    if let error = commandBuffer.error {
        throw error
    }
    return RenderFixtureResult(
        image: try image(from: outputTexture),
        modelViewMatrix: camera.viewMatrix,
        projectionMatrix: camera.projectionMatrix
    )
}

func image(from texture: MTLTexture) throws -> RGBAImage {
    let width = texture.width
    let height = texture.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var bgraPixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    texture.getBytes(
        &bgraPixels,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0
    )

    var rgbaPixels = [UInt8](repeating: 0, count: bgraPixels.count)
    for index in stride(from: 0, to: bgraPixels.count, by: 4) {
        rgbaPixels[index + 0] = bgraPixels[index + 2]
        rgbaPixels[index + 1] = bgraPixels[index + 1]
        rgbaPixels[index + 2] = bgraPixels[index + 0]
        rgbaPixels[index + 3] = bgraPixels[index + 3]
    }

    return RGBAImage(width: width, height: height, pixels: rgbaPixels)
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
              shouldInterpolate: true,
              intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw RuntimeError("Failed to create PNG destination")
    }

    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RuntimeError("Failed to write PNG to \(url.path)")
    }
}

func contentCoverage(_ image: RGBAImage, clearColor: SIMD4<Float>) -> (changedPixelRatio: Double, meanNormalizedDifference: Double) {
    let clear = [
        UInt8(max(0, min(255, Int((clearColor.x * 255.0).rounded())))),
        UInt8(max(0, min(255, Int((clearColor.y * 255.0).rounded())))),
        UInt8(max(0, min(255, Int((clearColor.z * 255.0).rounded())))),
        UInt8(max(0, min(255, Int((clearColor.w * 255.0).rounded())))),
    ]
    let pixelCount = image.width * image.height
    var changedPixelCount = 0
    var totalDifference = 0

    for pixelIndex in 0 ..< pixelCount {
        let base = pixelIndex * 4
        var pixelDifference = 0
        for channel in 0 ..< 4 {
            pixelDifference += abs(Int(image.pixels[base + channel]) - Int(clear[channel]))
        }
        totalDifference += pixelDifference
        if pixelDifference > 4 {
            changedPixelCount += 1
        }
    }

    return (
        Double(changedPixelCount) / Double(pixelCount),
        Double(totalDifference) / Double(pixelCount * 4 * 255)
    )
}

func verifyProjectedSamples(
    _ image: RGBAImage,
    modelViewMatrix: simd_float4x4,
    projectionMatrix: simd_float4x4
) throws {
    let fixtureSplats = SplatFixtures.deterministicScene()
    let renderSize = SIMD2<Float>(Float(image.width), Float(image.height))
    let clearColor = SIMD3<Float>(0.03, 0.035, 0.045)

    var failures: [String] = []
    for index in 0 ..< fixtureSplats.numSplats {
        let decoded = SplatReference.decodePackedSplat(
            fixtureSplats.packedWords(at: index),
            encoding: fixtureSplats.splatEncoding
        )
        guard let projected = SplatReference.project(
            decoded,
            modelViewMatrix: modelViewMatrix,
            projectionMatrix: projectionMatrix,
            renderSize: renderSize
        ) else {
            failures.append("sample[\(index)] CPU reference culled")
            continue
        }

        let pixel = pixelCenter(fromNDC: projected.ndcCenter.xy, width: image.width, height: image.height)
        let sampledRGB = pixelRGB(in: image, at: pixel)
        let expectedRGB = projected.rgba.xyz
        let expectedDominantChannel = dominantChannel(expectedRGB)
        let sampledDominantChannel = dominantChannel(sampledRGB)
        let sampledEnergy = max(sampledRGB.x, max(sampledRGB.y, sampledRGB.z))

        print(
            "sample[\(index)]",
            "expectedPixel=\(pixel.x),\(pixel.y)",
            "sampledRGB=\(sampledRGB)",
            "expectedRGB=\(expectedRGB)"
        )

        if sampledEnergy < 0.08 {
            failures.append("sample[\(index)] too dark at projected center: energy=\(sampledEnergy)")
        }
        if sampledDominantChannel != expectedDominantChannel {
            failures.append("sample[\(index)] dominant channel mismatch: sampled=\(sampledDominantChannel), expected=\(expectedDominantChannel)")
        }

        do {
            try verifyProjectedAxes(
                index: index,
                projected: projected,
                fixtureSplats: fixtureSplats,
                imageSize: SIMD2<Int>(image.width, image.height),
                clearColor: SIMD4<Float>(clearColor.x, clearColor.y, clearColor.z, 1.0)
            )
        } catch {
            failures.append("\(error)")
        }
    }

    if !failures.isEmpty {
        throw RuntimeError(failures.joined(separator: "\n"))
    }
}

func verifyProjectedAxes(
    index: Int,
    projected: ProjectedSplat,
    fixtureSplats: PackedSplats,
    imageSize: SIMD2<Int>,
    clearColor: SIMD4<Float>
) throws {
    let words = fixtureSplats.packedWords(at: index)
    let isolated = PackedSplats(
        packedArray: [words.x, words.y, words.z, words.w],
        numSplats: 1,
        splatEncoding: fixtureSplats.splatEncoding
    )
    let isolatedResult = try renderFixture(size: imageSize, clearColor: clearColor, packedSplats: isolated)
    let isolatedImage = isolatedResult.image
    let center = pixelCoordinate(fromNDC: projected.ndcCenter.xy, width: isolatedImage.width, height: isolatedImage.height)
    let axis1 = SIMD2<Float>(projected.axis1.x, -projected.axis1.y)
    let axis2 = SIMD2<Float>(projected.axis2.x, -projected.axis2.y)

    let insideSamples: [(String, SIMD2<Float>)] = [
        ("axis1+", center + axis1 * projected.radius1 * 0.65),
        ("axis1-", center - axis1 * projected.radius1 * 0.65),
        ("axis2+", center + axis2 * projected.radius2 * 0.65),
        ("axis2-", center - axis2 * projected.radius2 * 0.65),
    ]
    let outsideSamples: [(String, SIMD2<Float>)] = [
        ("axis1+", center + axis1 * projected.radius1 * 1.25),
        ("axis1-", center - axis1 * projected.radius1 * 1.25),
        ("axis2+", center + axis2 * projected.radius2 * 1.25),
        ("axis2-", center - axis2 * projected.radius2 * 1.25),
    ]

    var failures: [String] = []
    for (label, pixel) in insideSamples {
        let energy = maxDeviationFromClear(in: isolatedImage, near: pixel, clearColor: clearColor)
        print("axis[\(index)] inside \(label) pixel=\(pixel) energy=\(energy)")
        if energy < 0.08 {
            failures.append("axis[\(index)] \(label) too dark inside projected radius: energy=\(energy)")
        }
    }
    for (label, pixel) in outsideSamples {
        let energy = maxDeviationFromClear(in: isolatedImage, near: pixel, clearColor: clearColor)
        print("axis[\(index)] outside \(label) pixel=\(pixel) energy=\(energy)")
        if energy > 0.08 {
            failures.append("axis[\(index)] \(label) still visible outside projected radius: energy=\(energy)")
        }
    }

    if !failures.isEmpty {
        throw RuntimeError(failures.joined(separator: "\n"))
    }
}

func verifyAlphaFalloff(size: SIMD2<Int>, clearColor: SIMD4<Float>) throws {
    let alphaSplat = PackedSplats(splats: [
        PackedSplat(
            center: [0.0, 0.0, 0.0],
            scale: [0.11, 0.11, 0.11],
            opacity: 0.25,
            color: [1.0, 1.0, 1.0]
        ),
    ])
    let result = try renderFixture(size: size, clearColor: clearColor, packedSplats: alphaSplat)
    let image = result.image
    let decoded = SplatReference.decodePackedSplat(alphaSplat.packedWords(at: 0), encoding: alphaSplat.splatEncoding)
    guard let projected = SplatReference.project(
        decoded,
        modelViewMatrix: result.modelViewMatrix,
        projectionMatrix: result.projectionMatrix,
        renderSize: SIMD2<Float>(Float(size.x), Float(size.y))
    ) else {
        throw RuntimeError("alpha falloff fixture splat was culled")
    }

    let center = pixelCoordinate(fromNDC: projected.ndcCenter.xy, width: image.width, height: image.height)
    let axis1 = SIMD2<Float>(projected.axis1.x, -projected.axis1.y)
    let sourceRGB = decoded.rgba.xyz
    let clearRGB = clearColor.xyz
    let baseAlpha = min(decoded.rgba.w * 2.0, 1.0)
    let samples: [(String, Float)] = [
        ("center", 0.0),
        ("halfRadius", 0.5),
        ("threeQuarterRadius", 0.75),
    ]

    var previousAlpha: Float?
    var failures: [String] = []
    for (label, radiusFraction) in samples {
        let pixel = center + axis1 * projected.radius1 * radiusFraction
        let observedRGB = averagedRGB(in: image, near: pixel)
        let observedAlpha = inferredBlendAlpha(observedRGB: observedRGB, sourceRGB: sourceRGB, clearRGB: clearRGB)
        let expectedAlpha = baseAlpha * exp(-0.5 * pow(radiusFraction * projected.adjustedStdDev, 2.0))
        let error = abs(observedAlpha - expectedAlpha)
        print(
            "alphaFalloff[\(label)]",
            "pixel=\(pixel)",
            "observedAlpha=\(observedAlpha)",
            "expectedAlpha=\(expectedAlpha)",
            "error=\(error)"
        )

        if error > 0.04 {
            failures.append("alphaFalloff[\(label)] alpha mismatch: observed=\(observedAlpha), expected=\(expectedAlpha), error=\(error)")
        }
        if let previousAlpha, observedAlpha > previousAlpha + 0.02 {
            failures.append("alphaFalloff[\(label)] alpha increased with radius: previous=\(previousAlpha), observed=\(observedAlpha)")
        }
        previousAlpha = observedAlpha
    }

    if !failures.isEmpty {
        throw RuntimeError(failures.joined(separator: "\n"))
    }
}

func pixelCenter(fromNDC ndc: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Int> {
    let pixel = pixelCoordinate(fromNDC: ndc, width: width, height: height)
    return SIMD2<Int>(
        max(0, min(width - 1, Int(pixel.x.rounded()))),
        max(0, min(height - 1, Int(pixel.y.rounded())))
    )
}

func pixelCoordinate(fromNDC ndc: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
    let x = (ndc.x * 0.5 + 0.5) * Float(width - 1)
    let y = (1.0 - (ndc.y * 0.5 + 0.5)) * Float(height - 1)
    return SIMD2<Float>(x, y)
}

func pixelRGB(in image: RGBAImage, at pixel: SIMD2<Int>) -> SIMD3<Float> {
    let offset = (pixel.y * image.width + pixel.x) * 4
    return SIMD3<Float>(
        Float(image.pixels[offset + 0]) / 255.0,
        Float(image.pixels[offset + 1]) / 255.0,
        Float(image.pixels[offset + 2]) / 255.0
    )
}

func averagedRGB(in image: RGBAImage, near pixel: SIMD2<Float>) -> SIMD3<Float> {
    let centerX = max(0, min(image.width - 1, Int(pixel.x.rounded())))
    let centerY = max(0, min(image.height - 1, Int(pixel.y.rounded())))
    var sum = SIMD3<Float>(repeating: 0.0)
    var count: Float = 0.0

    for y in max(0, centerY - 1) ... min(image.height - 1, centerY + 1) {
        for x in max(0, centerX - 1) ... min(image.width - 1, centerX + 1) {
            sum += pixelRGB(in: image, at: SIMD2<Int>(x, y))
            count += 1.0
        }
    }
    return sum / max(count, 1.0)
}

func inferredBlendAlpha(observedRGB: SIMD3<Float>, sourceRGB: SIMD3<Float>, clearRGB: SIMD3<Float>) -> Float {
    var alphaSum: Float = 0.0
    var alphaCount: Float = 0.0
    for channel in 0 ..< 3 {
        let denominator = sourceRGB[channel] - clearRGB[channel]
        if abs(denominator) > 0.001 {
            alphaSum += (observedRGB[channel] - clearRGB[channel]) / denominator
            alphaCount += 1.0
        }
    }
    return max(0.0, min(1.0, alphaSum / max(alphaCount, 1.0)))
}

func dominantChannel(_ rgb: SIMD3<Float>) -> Int {
    if rgb.x >= rgb.y && rgb.x >= rgb.z { return 0 }
    if rgb.y >= rgb.z { return 1 }
    return 2
}

func maxDeviationFromClear(in image: RGBAImage, near pixel: SIMD2<Float>, clearColor: SIMD4<Float>) -> Float {
    let centerX = max(0, min(image.width - 1, Int(pixel.x.rounded())))
    let centerY = max(0, min(image.height - 1, Int(pixel.y.rounded())))
    let clear = SIMD3<Float>(clearColor.x, clearColor.y, clearColor.z)
    var maxDeviation: Float = 0.0

    for y in max(0, centerY - 1) ... min(image.height - 1, centerY + 1) {
        for x in max(0, centerX - 1) ... min(image.width - 1, centerX + 1) {
            let rgb = pixelRGB(in: image, at: SIMD2<Int>(x, y))
            maxDeviation = max(maxDeviation, max(abs(rgb.x - clear.x), max(abs(rgb.y - clear.y), abs(rgb.z - clear.z))))
        }
    }
    return maxDeviation
}

func readableTextureStorageMode() -> MTLStorageMode {
    #if arch(x86_64)
    return .managed
    #else
    return .shared
    #endif
}

struct RuntimeError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

private extension SIMD3 where Scalar == Float {
    var xy: SIMD2<Float> {
        SIMD2(x, y)
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}
