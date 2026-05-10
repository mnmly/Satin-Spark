import Foundation
import SatinSpark

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fputs("usage: satin-spark-pack-dump <input.ply|input.splat|...> <output.bin>\n", stderr)
    exit(2)
}

do {
    let inputArg = arguments[0]
    let outputURL = URL(fileURLWithPath: arguments[1])
    let splats: PackedSplats
    if inputArg == "fixture" {
        splats = SplatFixtures.deterministicScene()
    } else {
        splats = try SplatLoader.load(url: URL(fileURLWithPath: inputArg))
    }

    var data = Data()
    let sparkTextureWidth = 2048
    let paddedMaxSplats = ((splats.numSplats + sparkTextureWidth - 1) / sparkTextureWidth) * sparkTextureWidth
    var paddedPackedArray = splats.packedArray
    paddedPackedArray.append(contentsOf: repeatElement(0, count: max(0, paddedMaxSplats * 4 - paddedPackedArray.count)))

    append(UInt32(splats.numSplats), to: &data)
    append(UInt32(paddedMaxSplats), to: &data)
    append(splats.splatEncoding.rgbMin, to: &data)
    append(splats.splatEncoding.rgbMax, to: &data)
    append(splats.splatEncoding.lnScaleMin, to: &data)
    append(splats.splatEncoding.lnScaleMax, to: &data)
    for word in paddedPackedArray {
        append(word, to: &data)
    }

    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: outputURL, options: .atomic)
    print("wrote \(outputURL.path)")
    print("splats=\(splats.numSplats)")
    print("maxSplats=\(paddedMaxSplats)")
    print("words=\(paddedPackedArray.count)")
} catch {
    fputs("satin-spark-pack-dump: \(error)\n", stderr)
    exit(1)
}

func append(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

func append(_ value: Float, to data: inout Data) {
    append(value.bitPattern, to: &data)
}
