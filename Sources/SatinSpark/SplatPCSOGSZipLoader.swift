// PC-SOGS/SOG decoding is ported from https://github.com/sparkjsdev/spark —
// `src/pcsogs.ts` and `src/SplatLoader.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import CoreGraphics
import Foundation
import ImageIO
import simd
import zlib

public enum SplatPCSOGSZipLoaderError: LocalizedError {
    case invalidZip
    case unsupportedZipCompression(UInt16)
    case missingEntry(String)
    case invalidMetadata
    case unsupportedVersion(Int?)
    case invalidImage(String)
    case decompressionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidZip:
            return "The file is not a valid bundled PC-SOGS/SOG zip file."
        case let .unsupportedZipCompression(method):
            return "Unsupported SOG zip compression method: \(method)."
        case let .missingEntry(name):
            return "The SOG zip is missing required entry '\(name)'."
        case .invalidMetadata:
            return "The SOG metadata is invalid."
        case let .unsupportedVersion(version):
            return "Unsupported SOG metadata version: \(version.map(String.init) ?? "nil")."
        case let .invalidImage(name):
            return "Could not decode SOG image '\(name)'."
        case let .decompressionFailed(code):
            return "SOG zip entry decompression failed: zlib code \(code)."
        }
    }
}

public enum SplatPCSOGSZipLoader {
    public static func load(url: URL) throws -> PackedSplats {
        try parse(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func parse(_ data: Data, encoding: SplatEncoding = SplatEncoding()) throws -> PackedSplats {
        let entries = try unzipEntries(data)
        guard let metaEntry = entries.first(where: { $0.key.split(separator: "/").last == "meta.json" }) else {
            throw SplatPCSOGSZipLoaderError.missingEntry("meta.json")
        }
        let prefix = metaEntry.key.lastSlashPrefix

        return try parseSOGMetadataAndImages(metadataData: metaEntry.value, encoding: encoding) { fileName in
            try entry(named: prefix + fileName, in: entries)
        }
    }
}

public enum SplatPCSOGSLoader {
    public static func load(url: URL) throws -> PackedSplats {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try parse(data, baseURL: url.deletingLastPathComponent())
    }

    public static func parse(
        _ metadataData: Data,
        baseURL: URL,
        encoding: SplatEncoding = SplatEncoding()
    ) throws -> PackedSplats {
        try parseSOGMetadataAndImages(metadataData: metadataData, encoding: encoding) { fileName in
            let fileURL = baseURL.appendingPathComponent(fileName)
            do {
                return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            } catch {
                throw SplatPCSOGSZipLoaderError.missingEntry(fileName)
            }
        }
    }
}

private func parseSOGMetadataAndImages(
    metadataData: Data,
    encoding: SplatEncoding,
    readFile: (String) throws -> Data
) throws -> PackedSplats {
    let metadata = try JSONDecoder().decode(SOGMetadata.self, from: metadataData)
    guard metadata.version == 2, let numSplats = metadata.count else {
        throw SplatPCSOGSZipLoaderError.unsupportedVersion(metadata.version)
    }
    guard metadata.means.files.count >= 2,
          let meansMin = metadata.means.mins,
          let meansMax = metadata.means.maxs,
          meansMin.count >= 3,
          meansMax.count >= 3,
          let scaleCodebook = metadata.scales.codebook,
          let sh0Codebook = metadata.sh0.codebook,
          let scalesFile = metadata.scales.files.first,
          let quatsFile = metadata.quats.files.first,
          let sh0File = metadata.sh0.files.first else {
        throw SplatPCSOGSZipLoaderError.invalidMetadata
    }

    let meansLowFile = metadata.means.files[0]
    let meansHighFile = metadata.means.files[1]
    let meansLow = try decodeImageRGBA(readFile(meansLowFile), name: meansLowFile)
    let meansHigh = try decodeImageRGBA(readFile(meansHighFile), name: meansHighFile)
    let scales = try decodeImageRGBA(readFile(scalesFile), name: scalesFile)
    let quats = try decodeImageRGBA(readFile(quatsFile), name: quatsFile)
    let sh0 = try decodeImageRGBA(readFile(sh0File), name: sh0File)

    let requiredPixels = numSplats * 4
    guard meansLow.rgba.count >= requiredPixels,
          meansHigh.rgba.count >= requiredPixels,
          scales.rgba.count >= requiredPixels,
          quats.rgba.count >= requiredPixels,
          sh0.rgba.count >= requiredPixels else {
            throw SplatPCSOGSZipLoaderError.invalidMetadata
    }

    let sqrt2 = sqrt(Float(2.0))
    let quatLookup = (0 ..< 256).map { (Float($0) / 255.0 - 0.5) * sqrt2 }
    let scaleLookup = scaleCodebook.map { exp(Float($0)) }
    let colorLookup = sh0Codebook.map { Float(0.28209479177387814) * Float($0) + 0.5 }
    var packedArray = Array(repeating: UInt32(0), count: numSplats * 4)
    let sphericalHarmonics = try decodeSOGSphericalHarmonics(
        metadata.shN,
        numSplats: numSplats,
        encoding: encoding,
        readFile: readFile
    )

    for index in 0 ..< numSplats {
        let offset = index * 4
        let fx = Float(UInt16(meansLow.rgba[offset + 0]) | (UInt16(meansHigh.rgba[offset + 0]) << 8)) / 65535.0
        let fy = Float(UInt16(meansLow.rgba[offset + 1]) | (UInt16(meansHigh.rgba[offset + 1]) << 8)) / 65535.0
        let fz = Float(UInt16(meansLow.rgba[offset + 2]) | (UInt16(meansHigh.rgba[offset + 2]) << 8)) / 65535.0
        let encodedCenter = SIMD3<Float>(
            Float(meansMin[0]) + (Float(meansMax[0]) - Float(meansMin[0])) * fx,
            Float(meansMin[1]) + (Float(meansMax[1]) - Float(meansMin[1])) * fy,
            Float(meansMin[2]) + (Float(meansMax[2]) - Float(meansMin[2])) * fz
        )
        let center = SIMD3<Float>(
            signedExpMinusOne(encodedCenter.x),
            signedExpMinusOne(encodedCenter.y),
            signedExpMinusOne(encodedCenter.z)
        )

        let scale = SIMD3<Float>(
            scaleLookup[Int(scales.rgba[offset + 0])],
            scaleLookup[Int(scales.rgba[offset + 1])],
            scaleLookup[Int(scales.rgba[offset + 2])]
        )

        let r0 = quatLookup[Int(quats.rgba[offset + 0])]
        let r1 = quatLookup[Int(quats.rgba[offset + 1])]
        let r2 = quatLookup[Int(quats.rgba[offset + 2])]
        let rr = sqrt(max(0.0, 1.0 - r0 * r0 - r1 * r1 - r2 * r2))
        let rOrder = Int(quats.rgba[offset + 3]) - 252
        let rotation = normalizedPackedQuaternion(
            r: rOrder == 0 ? rr : r0,
            i: rOrder == 0 ? r0 : rOrder == 1 ? rr : r1,
            j: rOrder <= 1 ? r1 : rOrder == 2 ? rr : r2,
            k: rOrder <= 2 ? r2 : rr
        )

        let color = SIMD3<Float>(
            colorLookup[Int(sh0.rgba[offset + 0])],
            colorLookup[Int(sh0.rgba[offset + 1])],
            colorLookup[Int(sh0.rgba[offset + 2])]
        )
        let opacity = Float(sh0.rgba[offset + 3]) / 255.0

        writePackedSplatWords(
            center: center,
            scale: scale,
            rotation: rotation,
            color: color,
            opacity: opacity,
            encoding: encoding,
            into: &packedArray,
            at: index
        )
    }

    return PackedSplats(
        packedArray: packedArray,
        numSplats: numSplats,
        sphericalHarmonics: sphericalHarmonics,
        splatEncoding: encoding
    )
}

private struct SOGMetadata: Decodable {
    var version: Int?
    var count: Int?
    var means: SOGRangeFiles
    var scales: SOGCodebookFiles
    var quats: SOGFiles
    var sh0: SOGCodebookFiles
    var shN: SOGSphericalHarmonicsFiles?
}

private struct SOGRangeFiles: Decodable {
    var mins: [Double]?
    var maxs: [Double]?
    var files: [String]
}

private struct SOGCodebookFiles: Decodable {
    var codebook: [Double]?
    var files: [String]
}

private struct SOGFiles: Decodable {
    var files: [String]
}

private struct SOGSphericalHarmonicsFiles: Decodable {
    var bands: Int?
    var shape: [Int]?
    var mins: Double?
    var maxs: Double?
    var codebook: [Double]?
    var files: [String]
}

private struct RGBA8Image {
    var rgba: [UInt8]
    var width: Int
    var height: Int
}

private struct ZipEntry {
    var name: String
    var method: UInt16
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
}

private func entry(named name: String, in entries: [String: Data]) throws -> Data {
    guard let data = entries[name] else {
        throw SplatPCSOGSZipLoaderError.missingEntry(name)
    }
    return data
}

private func decodeImageRGBA(_ data: Data, name: String) throws -> RGBA8Image {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw SplatPCSOGSZipLoaderError.invalidImage(name)
    }
    let width = image.width
    let height = image.height
    var rgba = Array(repeating: UInt8(0), count: width * height * 4)
    guard let context = CGContext(
        data: &rgba,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw SplatPCSOGSZipLoaderError.invalidImage(name)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RGBA8Image(rgba: rgba, width: width, height: height)
}

private func decodeSOGSphericalHarmonics(
    _ shN: SOGSphericalHarmonicsFiles?,
    numSplats: Int,
    encoding: SplatEncoding,
    readFile: (String) throws -> Data
) throws -> PackedSphericalHarmonics {
    guard let shN else {
        return PackedSphericalHarmonics()
    }
    let bands = shN.bands ?? sogSHBandsFromShape(shN.shape)
    guard bands > 0 else {
        return PackedSphericalHarmonics()
    }
    guard shN.files.count >= 2 else {
        throw SplatPCSOGSZipLoaderError.invalidMetadata
    }

    let useSH1 = bands >= 1
    let useSH2 = bands >= 2
    let useSH3 = bands >= 3
    let degree = min(bands, 3)
    let lookup = try sogSHLookup(shN)
    let centroidsFile = shN.files[0]
    let labelsFile = shN.files[1]
    let centroids = try decodeImageRGBA(readFile(centroidsFile), name: centroidsFile)
    let labels = try decodeImageRGBA(readFile(labelsFile), name: labelsFile)
    guard labels.rgba.count >= numSplats * 4 else {
        throw SplatPCSOGSZipLoaderError.invalidMetadata
    }

    let maxCoefficientPixelOffset = useSH3 ? 14 : useSH2 ? 7 : 2
    var sphericalHarmonics = PackedSphericalHarmonics.storage(numSplats: numSplats, degree: degree)
    var sh1 = Array(repeating: Float(0), count: 9)
    var sh2 = Array(repeating: Float(0), count: 15)
    var sh3 = Array(repeating: Float(0), count: 21)

    for index in 0 ..< numSplats {
        let labelOffset = index * 4
        let label = Int(labels.rgba[labelOffset + 0]) | (Int(labels.rgba[labelOffset + 1]) << 8)
        let column = (label & 63) * 15
        let row = label >> 6
        let coefficientOffset = row * centroids.width + column
        let lastPixelOffset = coefficientOffset + maxCoefficientPixelOffset
        guard lastPixelOffset >= 0, (lastPixelOffset * 4 + 2) < centroids.rgba.count else {
            throw SplatPCSOGSZipLoaderError.invalidMetadata
        }

        for component in 0 ..< 3 {
            if useSH1 {
                for coefficient in 0 ..< 3 {
                    let pixelOffset = (coefficientOffset + coefficient) * 4
                    sh1[coefficient * 3 + component] = lookup[Int(centroids.rgba[pixelOffset + component])]
                }
            }
            if useSH2 {
                for coefficient in 0 ..< 5 {
                    let pixelOffset = (coefficientOffset + 3 + coefficient) * 4
                    sh2[coefficient * 3 + component] = lookup[Int(centroids.rgba[pixelOffset + component])]
                }
            }
            if useSH3 {
                for coefficient in 0 ..< 7 {
                    let pixelOffset = (coefficientOffset + 8 + coefficient) * 4
                    sh3[coefficient * 3 + component] = lookup[Int(centroids.rgba[pixelOffset + component])]
                }
            }
        }

        if useSH1 {
            sphericalHarmonics.setSH1(sh1, at: index, encoding: encoding)
        }
        if useSH2 {
            sphericalHarmonics.setSH2(sh2, at: index, encoding: encoding)
        }
        if useSH3 {
            sphericalHarmonics.setSH3(sh3, at: index, encoding: encoding)
        }
    }

    return sphericalHarmonics
}

private func sogSHBandsFromShape(_ shape: [Int]?) -> Int {
    guard let channelCount = shape?.dropFirst().first else {
        return 0
    }
    if channelCount >= 45 { return 3 }
    if channelCount >= 24 { return 2 }
    if channelCount >= 9 { return 1 }
    return 0
}

private func sogSHLookup(_ shN: SOGSphericalHarmonicsFiles) throws -> [Float] {
    if let codebook = shN.codebook {
        guard codebook.count >= 256 else {
            throw SplatPCSOGSZipLoaderError.invalidMetadata
        }
        return codebook.map { Float($0) }
    }
    guard let minValue = shN.mins, let maxValue = shN.maxs else {
        throw SplatPCSOGSZipLoaderError.invalidMetadata
    }
    return (0 ..< 256).map { index in
        Float(minValue + (maxValue - minValue) * (Double(index) / 255.0))
    }
}

private func unzipEntries(_ data: Data) throws -> [String: Data] {
    try data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        guard bytes.count >= 22, let eocd = findEndOfCentralDirectory(bytes) else {
            throw SplatPCSOGSZipLoaderError.invalidZip
        }
        let centralDirectoryCount = Int(zipReadUInt16(bytes, offset: eocd + 10))
        let centralDirectoryOffset = Int(zipReadUInt32(bytes, offset: eocd + 16))
        try zipRequireBytes(0, cursor: centralDirectoryOffset, count: bytes.count)

        var entries: [ZipEntry] = []
        var cursor = centralDirectoryOffset
        for _ in 0 ..< centralDirectoryCount {
            try zipRequireBytes(46, cursor: cursor, count: bytes.count)
            guard zipReadUInt32(bytes, offset: cursor) == 0x02014b50 else {
                throw SplatPCSOGSZipLoaderError.invalidZip
            }
            let method = zipReadUInt16(bytes, offset: cursor + 10)
            let compressedSize = Int(zipReadUInt32(bytes, offset: cursor + 20))
            let uncompressedSize = Int(zipReadUInt32(bytes, offset: cursor + 24))
            let nameLength = Int(zipReadUInt16(bytes, offset: cursor + 28))
            let extraLength = Int(zipReadUInt16(bytes, offset: cursor + 30))
            let commentLength = Int(zipReadUInt16(bytes, offset: cursor + 32))
            let localHeaderOffset = Int(zipReadUInt32(bytes, offset: cursor + 42))
            try zipRequireBytes(nameLength + extraLength + commentLength, cursor: cursor + 46, count: bytes.count)
            let name = String(
                decoding: UnsafeBufferPointer(start: bytes.baseAddress! + cursor + 46, count: nameLength),
                as: UTF8.self
            )
            entries.append(ZipEntry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }

        var result: [String: Data] = [:]
        for entry in entries {
            try zipRequireBytes(30, cursor: entry.localHeaderOffset, count: bytes.count)
            guard zipReadUInt32(bytes, offset: entry.localHeaderOffset) == 0x04034b50 else {
                throw SplatPCSOGSZipLoaderError.invalidZip
            }
            let localNameLength = Int(zipReadUInt16(bytes, offset: entry.localHeaderOffset + 26))
            let localExtraLength = Int(zipReadUInt16(bytes, offset: entry.localHeaderOffset + 28))
            let payloadOffset = entry.localHeaderOffset + 30 + localNameLength + localExtraLength
            try zipRequireBytes(entry.compressedSize, cursor: payloadOffset, count: bytes.count)
            let compressed = Data(bytes: bytes.baseAddress! + payloadOffset, count: entry.compressedSize)
            switch entry.method {
            case 0:
                result[entry.name] = compressed
            case 8:
                result[entry.name] = try inflateRawDeflate(compressed, uncompressedSize: entry.uncompressedSize)
            default:
                throw SplatPCSOGSZipLoaderError.unsupportedZipCompression(entry.method)
            }
        }
        return result
    }
}

private func inflateRawDeflate(_ data: Data, uncompressedSize: Int) throws -> Data {
    var stream = z_stream()
    var status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else {
        throw SplatPCSOGSZipLoaderError.decompressionFailed(status)
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    output.reserveCapacity(uncompressedSize)
    let chunkSize = 64 * 1024
    var chunk = Array(repeating: UInt8(0), count: chunkSize)

    try data.withUnsafeBytes { rawBuffer in
        guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            throw SplatPCSOGSZipLoaderError.invalidZip
        }
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source)
        stream.avail_in = uInt(rawBuffer.count)
        repeat {
            chunk.withUnsafeMutableBytes { outputBuffer in
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkSize)
                status = inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(outputBuffer.bindMemory(to: UInt8.self).baseAddress!, count: produced)
                }
            }
            guard status == Z_OK || status == Z_STREAM_END else {
                throw SplatPCSOGSZipLoaderError.decompressionFailed(status)
            }
        } while status != Z_STREAM_END
    }

    return output
}

private func findEndOfCentralDirectory(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
    let minimumOffset = max(0, bytes.count - 22 - 0xffff)
    guard bytes.count >= 22 else { return nil }
    for offset in stride(from: bytes.count - 22, through: minimumOffset, by: -1) {
        if zipReadUInt32(bytes, offset: offset) == 0x06054b50 {
            return offset
        }
    }
    return nil
}

private func zipRequireBytes(_ byteCount: Int, cursor: Int, count: Int) throws {
    guard byteCount >= 0, cursor >= 0, cursor + byteCount <= count else {
        throw SplatPCSOGSZipLoaderError.invalidZip
    }
}

@inline(__always)
private func zipReadUInt16(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

@inline(__always)
private func zipReadUInt32(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

@inline(__always)
private func signedExpMinusOne(_ value: Float) -> Float {
    (value < 0.0 ? -1.0 : 1.0) * (exp(abs(value)) - 1.0)
}

private extension String {
    var lastSlashPrefix: String {
        let slash = lastIndex(of: "/")
        let backslash = lastIndex(of: "\\")
        guard let index = [slash, backslash].compactMap({ $0 }).max() else {
            return ""
        }
        return String(self[...index])
    }
}
