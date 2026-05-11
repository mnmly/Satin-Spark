// RAD header decoding is ported from https://github.com/sparkjsdev/spark —
// `rust/spark-lib/src/rad.rs` and `src/SplatPager.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation
import simd
import zlib

public enum SplatRADLoaderError: LocalizedError {
    case incompleteHeader
    case invalidMagic(UInt32)
    case invalidChunkMagic(UInt32)
    case invalidMetadata
    case invalidChunkMetadata
    case unsupportedChunkVersion(Int)
    case unsupportedVersion(Int)
    case unsupportedType(String)
    case unsupportedChunkedSidecars
    case unsupportedChunkProperty(String, String)
    case unsupportedCompressedProperty(Int32)
    case decompressionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .incompleteHeader:
            return "The RAD header is incomplete."
        case let .invalidMagic(magic):
            return "Invalid RAD magic: 0x\(String(magic, radix: 16))."
        case let .invalidChunkMagic(magic):
            return "Invalid RAD chunk magic: 0x\(String(magic, radix: 16))."
        case .invalidMetadata:
            return "The RAD metadata is invalid."
        case .invalidChunkMetadata:
            return "The RAD chunk metadata is invalid."
        case let .unsupportedChunkVersion(version):
            return "Unsupported RAD chunk version: \(version)."
        case let .unsupportedVersion(version):
            return "Unsupported RAD metadata version: \(version)."
        case let .unsupportedType(type):
            return "Unsupported RAD type: \(type)."
        case .unsupportedChunkedSidecars:
            return "RAD sidecar chunks are not supported by the static PackedSplats loader."
        case let .unsupportedChunkProperty(property, encoding):
            return "Unsupported RAD chunk property '\(property)' with encoding '\(encoding)'."
        case let .unsupportedCompressedProperty(code):
            return "Could not initialize RAD property decompression: zlib code \(code)."
        case let .decompressionFailed(code):
            return "RAD property decompression failed: zlib code \(code)."
        }
    }
}

public struct SplatRADHeader: Sendable, Equatable {
    public var metadata: SplatRADMetadata
    public var chunksStart: Int
}

public struct SplatRADMetadata: Sendable, Equatable {
    public var version: Int
    public var type: String
    public var count: Int
    public var maxSH: Int?
    public var lodTree: Bool
    public var chunkSize: Int
    public var allChunkBytes: Int?
    public var chunks: [SplatRADChunkRange]
    public var splatEncoding: SplatEncoding?
}

public struct SplatRADChunkRange: Sendable, Equatable {
    public var offset: Int
    public var bytes: Int
    public var base: Int?
    public var count: Int?
    public var filename: String?
}

public struct SplatRADPage: Sendable {
    public var chunkIndex: Int
    public var base: Int
    public var count: Int
    public var splats: PackedSplats
    public var childCounts: [UInt16]?
    public var childStarts: [UInt32]?

    public func localChildStarts() -> [UInt32]? {
        guard let childStarts else { return nil }
        return childStarts.map { globalStart in
            let localStart = Int(globalStart) - base
            guard localStart >= 0, localStart < count else { return UInt32.max }
            return UInt32(localStart)
        }
    }

    public func lodRootIndex() -> Int {
        guard count > 0,
              let childCounts,
              let allParents = inverseParentIndicesFromChildRanges() else {
            return max(0, count - 1)
        }

        var root = count - 1
        var visited = Set<Int>()
        while root >= 0, root < count, !visited.contains(root) {
            visited.insert(root)
            let parent = allParents[root]
            guard parent != UInt32.max else { return root }
            root = Int(parent)
        }

        var bestRoot = max(0, count - 1)
        var bestChildCount = UInt16.min
        for index in 0 ..< count where allParents[index] == UInt32.max && childCounts[index] > bestChildCount {
            bestRoot = index
            bestChildCount = childCounts[index]
        }
        return bestRoot
    }

    public func parentIndices() -> [UInt32]? {
        guard let childCounts, let localChildStarts = localChildStarts() else { return nil }
        var parents = Array(repeating: UInt32.max, count: count)
        guard count > 0 else { return parents }

        var stack = [lodRootIndex()]
        var visited = Set<Int>()
        while let parent = stack.popLast() {
            guard parent >= 0, parent < count, !visited.contains(parent) else { continue }
            visited.insert(parent)

            let childCount = Int(childCounts[parent])
            guard childCount > 0 else { continue }
            let childStart = Int(localChildStarts[parent])
            guard childStart >= 0, childStart + childCount <= count else { continue }

            for child in childStart ..< childStart + childCount {
                guard child != parent else { continue }
                parents[child] = UInt32(parent)
                if !visited.contains(child) {
                    stack.append(child)
                }
            }
        }

        return parents
    }

    private func inverseParentIndicesFromChildRanges() -> [UInt32]? {
        guard let childCounts, let localChildStarts = localChildStarts() else { return nil }
        var parents = Array(repeating: UInt32.max, count: count)

        for parent in 0 ..< count {
            let childCount = Int(childCounts[parent])
            guard childCount > 0 else { continue }
            let childStart = Int(localChildStarts[parent])
            guard childStart >= 0, childStart + childCount <= count else { continue }

            for child in childStart ..< childStart + childCount where child != parent {
                parents[child] = UInt32(parent)
            }
        }

        return parents
    }

    public func selectLOD(
        modelViewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        renderSize: SIMD2<Float>,
        splitPixelRadius: Float = 2.0,
        maxSelectedSplats: Int? = nil
    ) -> [UInt32] {
        guard count > 0 else { return [] }
        guard let childCounts, let childStarts else {
            return (0 ..< count).map { UInt32($0) }
        }

        var selected: [UInt32] = []
        selected.reserveCapacity(min(count, maxSelectedSplats ?? count))
        var stack = [lodRootIndex()]
        var visited = Set<Int>()

        while let localIndex = stack.popLast() {
            guard localIndex >= 0, localIndex < count, !visited.contains(localIndex) else { continue }
            visited.insert(localIndex)

            let decoded = SplatReference.decodePackedSplat(
                splats.packedWords(at: localIndex),
                encoding: splats.splatEncoding
            )
            let projected = SplatReference.project(
                decoded,
                modelViewMatrix: modelViewMatrix,
                projectionMatrix: projectionMatrix,
                renderSize: renderSize
            )
            let projectedRadius = projected.map { max($0.radius1, $0.radius2) } ?? 0.0
            let childCount = Int(childCounts[localIndex])
            let globalChildStart = Int(childStarts[localIndex])
            let localChildStart = globalChildStart - base
            let canSplit = childCount > 0
                && localChildStart >= 0
                && localChildStart + childCount <= count
                && projectedRadius > splitPixelRadius

            if canSplit {
                for child in stride(from: localChildStart + childCount - 1, through: localChildStart, by: -1) {
                    stack.append(child)
                }
            } else {
                selected.append(UInt32(localIndex))
                if let maxSelectedSplats, selected.count >= maxSelectedSplats {
                    break
                }
            }
        }

        return selected
    }
}

public final class SplatRADPagedFile {
    public let url: URL
    public let header: SplatRADHeader

    public init(url: URL) throws {
        self.url = url
        self.header = try SplatRADLoader.loadHeader(url: url)
    }

    public func loadChunk(_ chunkIndex: Int) throws -> SplatRADPage {
        try SplatRADLoader.loadPage(url: url, header: header, chunkIndex: chunkIndex)
    }

    public func loadRootChunk() throws -> SplatRADPage {
        try loadChunk(max(0, header.metadata.chunks.count - 1))
    }
}

public enum SplatRADLoader {
    public static func loadHeader(url: URL) throws -> SplatRADHeader {
        try parseHeader(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func load(url: URL) throws -> PackedSplats {
        try parse(
            Data(contentsOf: url, options: [.mappedIfSafe]),
            sidecarBaseURL: url.deletingLastPathComponent()
        )
    }

    public static func parse(_ data: Data) throws -> PackedSplats {
        try parse(data, sidecarBaseURL: nil)
    }

    public static func loadPage(url: URL, chunkIndex: Int) throws -> SplatRADPage {
        try loadPage(url: url, header: loadHeader(url: url), chunkIndex: chunkIndex)
    }

    public static func loadPage(url: URL, header: SplatRADHeader, chunkIndex: Int) throws -> SplatRADPage {
        guard chunkIndex >= 0, chunkIndex < header.metadata.chunks.count else {
            throw SplatRADLoaderError.invalidMetadata
        }
        let range = header.metadata.chunks[chunkIndex]
        if let filename = range.filename {
            let chunkURL = url.deletingLastPathComponent().appendingPathComponent(filename)
            let chunkData = try Data(contentsOf: chunkURL, options: [.mappedIfSafe])
            return try decodePage(
                chunkIndex: chunkIndex,
                header: header,
                range: range,
                chunkData: chunkData,
                chunkStart: range.offset
            )
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decodePage(
            chunkIndex: chunkIndex,
            header: header,
            range: range,
            chunkData: data,
            chunkStart: header.chunksStart + range.offset
        )
    }

    private static func parse(_ data: Data, sidecarBaseURL: URL?) throws -> PackedSplats {
        let header = try parseHeader(data)

        var encoding = header.metadata.splatEncoding ?? SplatEncoding()
        if header.metadata.lodTree {
            encoding.lodOpacity = true
        }

        var centers = Array(repeating: SIMD3<Float>(repeating: 0.0), count: header.metadata.count)
        var colors = Array(repeating: SIMD3<Float>(repeating: 1.0), count: header.metadata.count)
        var opacities = Array(repeating: Float(1.0), count: header.metadata.count)
        var scales = Array(repeating: SIMD3<Float>(repeating: SparkConstants.scaleZero), count: header.metadata.count)
        var rotations = Array(
            repeating: simd_quatf(angle: 0.0, axis: [1.0, 0.0, 0.0]),
            count: header.metadata.count
        )
        var sphericalHarmonics = PackedSphericalHarmonics.storage(
            numSplats: header.metadata.count,
            degree: header.metadata.maxSH ?? 0
        )

        for range in header.metadata.chunks {
            let chunkData: Data
            let chunkStart: Int
            if let filename = range.filename {
                guard let sidecarBaseURL else {
                    throw SplatRADLoaderError.unsupportedChunkedSidecars
                }
                chunkData = try Data(contentsOf: sidecarBaseURL.appendingPathComponent(filename), options: [.mappedIfSafe])
                chunkStart = range.offset
            } else {
                chunkData = data
                chunkStart = header.chunksStart + range.offset
            }

            try chunkData.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                let chunkEnd = chunkStart + range.bytes
                guard chunkStart >= 0, chunkEnd <= bytes.count, chunkStart <= chunkEnd else {
                    throw SplatRADLoaderError.invalidMetadata
                }
                let chunk = try parseChunkHeader(bytes, chunkStart: chunkStart, chunkEnd: chunkEnd)
                let base = range.base ?? chunk.metadata.base
                let count = range.count ?? chunk.metadata.count
                guard base >= 0, count >= 0, base + count <= header.metadata.count else {
                    throw SplatRADLoaderError.invalidChunkMetadata
                }

                for property in chunk.metadata.properties {
                    let propertyStart = chunk.payloadStart + property.offset
                    let propertyEnd = propertyStart + property.bytes
                    guard propertyStart >= chunk.payloadStart,
                          propertyEnd <= chunk.payloadEnd,
                          propertyEnd <= bytes.count else {
                        throw SplatRADLoaderError.invalidChunkMetadata
                    }

                    let raw = Data(bytes: bytes.baseAddress! + propertyStart, count: property.bytes)
                    let propertyData = try decodePropertyData(raw, compression: property.compression)
                    switch property.property {
                    case .center:
                        let values = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                        for index in 0 ..< count {
                            centers[base + index] = SIMD3<Float>(
                                values[index * 3 + 0],
                                values[index * 3 + 1],
                                values[index * 3 + 2]
                            )
                        }
                    case .alpha:
                        let values = try decodeFloatProperty(propertyData, property: property, elements: 1, count: count)
                        for index in 0 ..< count {
                            opacities[base + index] = values[index]
                        }
                    case .rgb:
                        let values = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                        for index in 0 ..< count {
                            colors[base + index] = SIMD3<Float>(
                                values[index * 3 + 0],
                                values[index * 3 + 1],
                                values[index * 3 + 2]
                            )
                        }
                    case .scales:
                        let values = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                        for index in 0 ..< count {
                            scales[base + index] = SIMD3<Float>(
                                values[index * 3 + 0],
                                values[index * 3 + 1],
                                values[index * 3 + 2]
                            )
                        }
                    case .orientation:
                        let values: [Float]
                        if property.encoding == .oct88R8 {
                            values = try decodeQuatOct88R8(propertyData, count: count)
                        } else {
                            let xyz = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                            var quaternions: [Float] = []
                            quaternions.reserveCapacity(count * 4)
                            for index in 0 ..< count {
                                let x = xyz[index * 3 + 0]
                                let y = xyz[index * 3 + 1]
                                let z = xyz[index * 3 + 2]
                                let w = sqrt(max(0.0, 1.0 - x * x - y * y - z * z))
                                quaternions.append(contentsOf: [x, y, z, w])
                            }
                            values = quaternions
                        }
                        for index in 0 ..< count {
                            rotations[base + index] = normalizedPackedQuaternion(
                                r: values[index * 4 + 3],
                                i: values[index * 4 + 0],
                                j: values[index * 4 + 1],
                                k: values[index * 4 + 2]
                            )
                        }
                    case .sh1, .sh2, .sh3:
                        let elements = property.property.shElementCount
                        let values = try decodeFloatProperty(propertyData, property: property, elements: elements, count: count)
                        for index in 0 ..< count {
                            let start = index * elements
                            let coeffs = Array(values[start ..< start + elements])
                            switch property.property {
                            case .sh1:
                                sphericalHarmonics.setSH1(coeffs, at: base + index, encoding: encoding)
                            case .sh2:
                                sphericalHarmonics.setSH2(coeffs, at: base + index, encoding: encoding)
                            case .sh3:
                                sphericalHarmonics.setSH3(coeffs, at: base + index, encoding: encoding)
                            default:
                                break
                            }
                        }
                    case .childCount, .childStart, .sh1Code, .sh2Code, .sh3Code, .shLabel:
                        break
                    }
                }
            }
        }

        var packedArray = Array(repeating: UInt32(0), count: header.metadata.count * 4)
        for index in 0 ..< header.metadata.count {
            writePackedSplatWords(
                center: centers[index],
                scale: scales[index],
                rotation: rotations[index],
                color: colors[index],
                opacity: opacities[index],
                encoding: encoding,
                into: &packedArray,
                at: index
            )
        }

        return PackedSplats(
            packedArray: packedArray,
            numSplats: header.metadata.count,
            sphericalHarmonics: sphericalHarmonics,
            splatEncoding: encoding
        )
    }

    public static func parseHeader(_ data: Data) throws -> SplatRADHeader {
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 8 else { throw SplatRADLoaderError.incompleteHeader }
            let magic = readLittleUInt32(bytes, offset: 0)
            guard magic == 0x3044_4152 else { throw SplatRADLoaderError.invalidMagic(magic) }

            let metadataByteCount = Int(readLittleUInt32(bytes, offset: 4))
            guard bytes.count >= 8 + metadataByteCount else {
                throw SplatRADLoaderError.incompleteHeader
            }

            let metadataData = Data(bytes: bytes.baseAddress! + 8, count: metadataByteCount)
            let decoded = try JSONDecoder().decode(RADMetadataJSON.self, from: metadataData)
            guard decoded.version == 1 else { throw SplatRADLoaderError.unsupportedVersion(decoded.version) }
            guard decoded.type == "gsplat" else { throw SplatRADLoaderError.unsupportedType(decoded.type) }
            guard decoded.count >= 0, !decoded.chunks.isEmpty else {
                throw SplatRADLoaderError.invalidMetadata
            }

            let chunkSize = decoded.chunkSize ?? decoded.count
            guard chunkSize > 0 else { throw SplatRADLoaderError.invalidMetadata }
            let expectedChunkCount = (decoded.count + chunkSize - 1) / chunkSize
            guard decoded.chunks.count == expectedChunkCount else {
                throw SplatRADLoaderError.invalidMetadata
            }

            let metadata = SplatRADMetadata(
                version: decoded.version,
                type: decoded.type,
                count: decoded.count,
                maxSH: decoded.maxSH,
                lodTree: decoded.lodTree ?? false,
                chunkSize: chunkSize,
                allChunkBytes: decoded.allChunkBytes,
                chunks: decoded.chunks.map {
                    SplatRADChunkRange(
                        offset: $0.offset,
                        bytes: $0.bytes,
                        base: $0.base,
                        count: $0.count,
                        filename: $0.filename
                    )
                },
                splatEncoding: decoded.splatEncoding?.splatEncoding
            )

            return SplatRADHeader(metadata: metadata, chunksStart: 8 + roundUpToEight(metadataByteCount))
        }
    }

    public static func decodePage(
        chunkIndex: Int,
        header: SplatRADHeader,
        range: SplatRADChunkRange,
        chunkData: Data,
        chunkStart: Int
    ) throws -> SplatRADPage {
        var encoding = header.metadata.splatEncoding ?? SplatEncoding()
        if header.metadata.lodTree {
            encoding.lodOpacity = true
        }

        return try chunkData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let chunkEnd = chunkStart + range.bytes
            guard chunkStart >= 0, chunkEnd <= bytes.count, chunkStart <= chunkEnd else {
                throw SplatRADLoaderError.invalidMetadata
            }
            let chunk = try parseChunkHeader(bytes, chunkStart: chunkStart, chunkEnd: chunkEnd)
            let base = range.base ?? chunk.metadata.base
            let count = range.count ?? chunk.metadata.count
            guard base >= 0, count >= 0, base + count <= header.metadata.count else {
                throw SplatRADLoaderError.invalidChunkMetadata
            }

            var centers = Array(repeating: SIMD3<Float>(repeating: 0.0), count: count)
            var colors = Array(repeating: SIMD3<Float>(repeating: 1.0), count: count)
            var opacities = Array(repeating: Float(1.0), count: count)
            var scales = Array(repeating: SIMD3<Float>(repeating: SparkConstants.scaleZero), count: count)
            var rotations = Array(
                repeating: simd_quatf(angle: 0.0, axis: [1.0, 0.0, 0.0]),
                count: count
            )
            var sphericalHarmonics = PackedSphericalHarmonics.storage(
                numSplats: count,
                degree: header.metadata.maxSH ?? 0
            )
            var childCounts: [UInt16]?
            var childStarts: [UInt32]?

            for property in chunk.metadata.properties {
                let propertyStart = chunk.payloadStart + property.offset
                let propertyEnd = propertyStart + property.bytes
                guard propertyStart >= chunk.payloadStart,
                      propertyEnd <= chunk.payloadEnd,
                      propertyEnd <= bytes.count else {
                    throw SplatRADLoaderError.invalidChunkMetadata
                }

                let raw = Data(bytes: bytes.baseAddress! + propertyStart, count: property.bytes)
                let propertyData = try decodePropertyData(raw, compression: property.compression)
                switch property.property {
                case .center:
                    let values = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                    for index in 0 ..< count {
                        centers[index] = SIMD3<Float>(values[index * 3 + 0], values[index * 3 + 1], values[index * 3 + 2])
                    }
                case .alpha:
                    let values = try decodeFloatProperty(propertyData, property: property, elements: 1, count: count)
                    for index in 0 ..< count {
                        opacities[index] = values[index]
                    }
                case .rgb:
                    let values = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                    for index in 0 ..< count {
                        colors[index] = SIMD3<Float>(values[index * 3 + 0], values[index * 3 + 1], values[index * 3 + 2])
                    }
                case .scales:
                    let values = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                    for index in 0 ..< count {
                        scales[index] = SIMD3<Float>(values[index * 3 + 0], values[index * 3 + 1], values[index * 3 + 2])
                    }
                case .orientation:
                    let values: [Float]
                    if property.encoding == .oct88R8 {
                        values = try decodeQuatOct88R8(propertyData, count: count)
                    } else {
                        let xyz = try decodeFloatProperty(propertyData, property: property, elements: 3, count: count)
                        var quaternions: [Float] = []
                        quaternions.reserveCapacity(count * 4)
                        for index in 0 ..< count {
                            let x = xyz[index * 3 + 0]
                            let y = xyz[index * 3 + 1]
                            let z = xyz[index * 3 + 2]
                            let w = sqrt(max(0.0, 1.0 - x * x - y * y - z * z))
                            quaternions.append(contentsOf: [x, y, z, w])
                        }
                        values = quaternions
                    }
                    for index in 0 ..< count {
                        rotations[index] = normalizedPackedQuaternion(
                            r: values[index * 4 + 3],
                            i: values[index * 4 + 0],
                            j: values[index * 4 + 1],
                            k: values[index * 4 + 2]
                        )
                    }
                case .sh1, .sh2, .sh3:
                    let elements = property.property.shElementCount
                    let values = try decodeFloatProperty(propertyData, property: property, elements: elements, count: count)
                    for index in 0 ..< count {
                        let start = index * elements
                        let coeffs = Array(values[start ..< start + elements])
                        switch property.property {
                        case .sh1:
                            sphericalHarmonics.setSH1(coeffs, at: index, encoding: encoding)
                        case .sh2:
                            sphericalHarmonics.setSH2(coeffs, at: index, encoding: encoding)
                        case .sh3:
                            sphericalHarmonics.setSH3(coeffs, at: index, encoding: encoding)
                        default:
                            break
                        }
                    }
                case .childCount:
                    childCounts = try decodeUInt16Property(propertyData, property: property, count: count)
                case .childStart:
                    childStarts = try decodeUInt32Property(propertyData, property: property, count: count)
                case .sh1Code, .sh2Code, .sh3Code, .shLabel:
                    break
                }
            }

            var packedArray = Array(repeating: UInt32(0), count: count * 4)
            for index in 0 ..< count {
                writePackedSplatWords(
                    center: centers[index],
                    scale: scales[index],
                    rotation: rotations[index],
                    color: colors[index],
                    opacity: opacities[index],
                    encoding: encoding,
                    into: &packedArray,
                    at: index
                )
            }
            let splats = PackedSplats(
                packedArray: packedArray,
                numSplats: count,
                sphericalHarmonics: sphericalHarmonics,
                splatEncoding: encoding
            )
            return SplatRADPage(
                chunkIndex: chunkIndex,
                base: base,
                count: count,
                splats: splats,
                childCounts: childCounts,
                childStarts: childStarts
            )
        }
    }
}

private struct ParsedRADChunk {
    var metadata: RADChunkMetadataJSON
    var payloadStart: Int
    var payloadEnd: Int
}

private struct RADChunkMetadataJSON: Decodable {
    var version: Int
    var base: Int
    var count: Int
    var payloadBytes: Int
    var maxSH: Int?
    var lodTree: Bool?
    var splatEncoding: RADSplatEncodingJSON?
    var properties: [RADChunkPropertyJSON]

    private enum CodingKeys: String, CodingKey {
        case version
        case base
        case count
        case payloadBytes
        case maxSH = "maxSh"
        case lodTree
        case splatEncoding
        case properties
    }
}

private struct RADChunkPropertyJSON: Decodable {
    var offset: Int
    var bytes: Int
    var property: RADChunkPropertyName
    var encoding: RADChunkPropertyEncoding
    var compression: RADChunkPropertyCompression?
    var min: Float?
    var max: Float?
}

private enum RADChunkPropertyName: String, Decodable {
    case center
    case alpha
    case rgb
    case scales
    case orientation
    case sh1
    case sh2
    case sh3
    case childCount = "child_count"
    case childStart = "child_start"
    case sh1Code = "sh1_code"
    case sh2Code = "sh2_code"
    case sh3Code = "sh3_code"
    case shLabel = "sh_label"

    var shElementCount: Int {
        switch self {
        case .sh1:
            return 9
        case .sh2:
            return 15
        case .sh3:
            return 21
        default:
            return 0
        }
    }
}

private enum RADChunkPropertyEncoding: String, Decodable {
    case f32
    case f16
    case f32LeBytes = "f32_lebytes"
    case f16LeBytes = "f16_lebytes"
    case r8
    case r8Delta = "r8_delta"
    case s8
    case s8Delta = "s8_delta"
    case ln0R8 = "ln_0r8"
    case lnF16 = "ln_f16"
    case oct88R8 = "oct88r8"
    case u16
    case u32
}

private enum RADChunkPropertyCompression: String, Decodable {
    case gz
}

private func parseChunkHeader(
    _ bytes: UnsafeBufferPointer<UInt8>,
    chunkStart: Int,
    chunkEnd: Int
) throws -> ParsedRADChunk {
    guard chunkEnd - chunkStart >= 16 else { throw SplatRADLoaderError.incompleteHeader }
    let magic = readLittleUInt32(bytes, offset: chunkStart)
    guard magic == 0x4344_4152 else { throw SplatRADLoaderError.invalidChunkMagic(magic) }
    let metadataByteCount = Int(readLittleUInt32(bytes, offset: chunkStart + 4))
    let metadataEnd = chunkStart + 8 + roundUpToEight(metadataByteCount)
    guard metadataEnd + 8 <= chunkEnd else { throw SplatRADLoaderError.incompleteHeader }

    let metadataData = Data(bytes: bytes.baseAddress! + chunkStart + 8, count: metadataByteCount)
    let metadata = try JSONDecoder().decode(RADChunkMetadataJSON.self, from: metadataData)
    guard metadata.version == 1 else {
        throw SplatRADLoaderError.unsupportedChunkVersion(metadata.version)
    }
    guard metadata.count >= 0, metadata.payloadBytes >= 0 else {
        throw SplatRADLoaderError.invalidChunkMetadata
    }

    let payloadBytes = Int(readLittleUInt64(bytes, offset: metadataEnd))
    guard payloadBytes == metadata.payloadBytes else {
        throw SplatRADLoaderError.invalidChunkMetadata
    }
    let payloadStart = metadataEnd + 8
    let payloadEnd = payloadStart + payloadBytes
    guard payloadEnd <= chunkEnd else { throw SplatRADLoaderError.incompleteHeader }
    return ParsedRADChunk(metadata: metadata, payloadStart: payloadStart, payloadEnd: payloadEnd)
}

private func decodePropertyData(_ data: Data, compression: RADChunkPropertyCompression?) throws -> Data {
    guard let compression else { return data }
    switch compression {
    case .gz:
        return try inflate(data)
    }
}

private func decodeFloatProperty(
    _ data: Data,
    property: RADChunkPropertyJSON,
    elements: Int,
    count: Int
) throws -> [Float] {
    switch property.encoding {
    case .f32:
        return try decodeF32(data, elements: elements, count: count)
    case .f16:
        return try decodeF16(data, elements: elements, count: count)
    case .f32LeBytes:
        return try decodeF32LeBytes(data, elements: elements, count: count)
    case .f16LeBytes:
        return try decodeF16LeBytes(data, elements: elements, count: count)
    case .r8:
        guard let min = property.min, let max = property.max else {
            throw SplatRADLoaderError.invalidChunkMetadata
        }
        return try decodeR8(data, elements: elements, count: count, min: min, max: max, delta: false)
    case .r8Delta:
        guard let min = property.min, let max = property.max else {
            throw SplatRADLoaderError.invalidChunkMetadata
        }
        return try decodeR8(data, elements: elements, count: count, min: min, max: max, delta: true)
    case .s8:
        guard let max = property.max else { throw SplatRADLoaderError.invalidChunkMetadata }
        return try decodeS8(data, elements: elements, count: count, max: max, delta: false)
    case .s8Delta:
        guard let max = property.max else { throw SplatRADLoaderError.invalidChunkMetadata }
        return try decodeS8(data, elements: elements, count: count, max: max, delta: true)
    case .ln0R8:
        guard let min = property.min, let max = property.max else {
            throw SplatRADLoaderError.invalidChunkMetadata
        }
        return try decodeLn0R8(data, elements: elements, count: count, min: min, max: max)
    case .lnF16:
        return try decodeLnF16(data, elements: elements, count: count)
    case .oct88R8, .u16, .u32:
        throw SplatRADLoaderError.unsupportedChunkProperty(property.property.rawValue, property.encoding.rawValue)
    }
}

private func decodeUInt16Property(
    _ data: Data,
    property: RADChunkPropertyJSON,
    count: Int
) throws -> [UInt16] {
    guard property.encoding == .u16 else {
        throw SplatRADLoaderError.unsupportedChunkProperty(property.property.rawValue, property.encoding.rawValue)
    }
    try requireDataByteCount(data, count * 2)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        return (0 ..< count).map { readLittleUInt16(bytes, offset: $0 * 2) }
    }
}

private func decodeUInt32Property(
    _ data: Data,
    property: RADChunkPropertyJSON,
    count: Int
) throws -> [UInt32] {
    guard property.encoding == .u32 else {
        throw SplatRADLoaderError.unsupportedChunkProperty(property.property.rawValue, property.encoding.rawValue)
    }
    try requireDataByteCount(data, count * 4)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        return (0 ..< count).map { readLittleUInt32(bytes, offset: $0 * 4) }
    }
}

private func decodeF32(_ data: Data, elements: Int, count: Int) throws -> [Float] {
    try requireDataByteCount(data, elements * count * 4)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var result: [Float] = []
        result.reserveCapacity(elements * count)
        for index in 0 ..< count {
            var offset = index * 4
            for _ in 0 ..< elements {
                result.append(readFloat32(bytes, offset: offset))
                offset += count * 4
            }
        }
        return result
    }
}

private func decodeF16(_ data: Data, elements: Int, count: Int) throws -> [Float] {
    try requireDataByteCount(data, elements * count * 2)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var result: [Float] = []
        result.reserveCapacity(elements * count)
        for index in 0 ..< count {
            var offset = index * 2
            for _ in 0 ..< elements {
                result.append(Float(Float16(bitPattern: readLittleUInt16(bytes, offset: offset))))
                offset += count * 2
            }
        }
        return result
    }
}

private func decodeF32LeBytes(_ data: Data, elements: Int, count: Int) throws -> [Float] {
    try requireDataByteCount(data, elements * count * 4)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        let stride = elements * count
        var result: [Float] = []
        result.reserveCapacity(elements * count)
        for index in 0 ..< count {
            for element in 0 ..< elements {
                let byteIndex = count * element + index
                let bits = UInt32(bytes[byteIndex])
                    | (UInt32(bytes[byteIndex + stride]) << 8)
                    | (UInt32(bytes[byteIndex + stride * 2]) << 16)
                    | (UInt32(bytes[byteIndex + stride * 3]) << 24)
                result.append(Float(bitPattern: bits))
            }
        }
        return result
    }
}

private func decodeF16LeBytes(_ data: Data, elements: Int, count: Int) throws -> [Float] {
    try requireDataByteCount(data, elements * count * 2)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        let stride = elements * count
        var result: [Float] = []
        result.reserveCapacity(elements * count)
        for index in 0 ..< count {
            for element in 0 ..< elements {
                let byteIndex = count * element + index
                let bits = UInt16(bytes[byteIndex]) | (UInt16(bytes[byteIndex + stride]) << 8)
                result.append(Float(Float16(bitPattern: bits)))
            }
        }
        return result
    }
}

private func decodeR8(
    _ data: Data,
    elements: Int,
    count: Int,
    min: Float,
    max: Float,
    delta: Bool
) throws -> [Float] {
    try requireDataByteCount(data, elements * count)
    var last = Array(repeating: UInt8(0), count: elements)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var result: [Float] = []
        result.reserveCapacity(elements * count)
        for index in 0 ..< count {
            var byteIndex = index
            for element in 0 ..< elements {
                let value = delta ? last[element] &+ bytes[byteIndex] : bytes[byteIndex]
                last[element] = value
                result.append((Float(value) / 255.0) * (max - min) + min)
                byteIndex += count
            }
        }
        return result
    }
}

private func decodeS8(
    _ data: Data,
    elements: Int,
    count: Int,
    max: Float,
    delta: Bool
) throws -> [Float] {
    try requireDataByteCount(data, elements * count)
    var last = Array(repeating: UInt8(0), count: elements)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var result: [Float] = []
        result.reserveCapacity(elements * count)
        for index in 0 ..< count {
            var byteIndex = index
            for element in 0 ..< elements {
                let value = delta ? last[element] &+ bytes[byteIndex] : bytes[byteIndex]
                last[element] = value
                result.append((Float(Int8(bitPattern: value)) / 127.0) * max)
                byteIndex += count
            }
        }
        return result
    }
}

private func decodeLn0R8(_ data: Data, elements: Int, count: Int, min: Float, max: Float) throws -> [Float] {
    try requireDataByteCount(data, elements * count)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        let scaleStep = (max - min) / 254.0
        var result: [Float] = []
        result.reserveCapacity(elements * count)
        for index in 0 ..< count {
            var byteIndex = index
            for _ in 0 ..< elements {
                let value = bytes[byteIndex]
                result.append(value == 0 ? 0.0 : exp(min + Float(value - 1) * scaleStep))
                byteIndex += count
            }
        }
        return result
    }
}

private func decodeLnF16(_ data: Data, elements: Int, count: Int) throws -> [Float] {
    try decodeF16(data, elements: elements, count: count).map(exp)
}

private func decodeQuatOct88R8(_ data: Data, count: Int) throws -> [Float] {
    try requireDataByteCount(data, count * 3)
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var result: [Float] = []
        result.reserveCapacity(count * 4)
        for index in 0 ..< count {
            let offset = index * 3
            var x = Float(bytes[offset + 0]) / 255.0 * 2.0 - 1.0
            var y = Float(bytes[offset + 1]) / 255.0 * 2.0 - 1.0
            let z = 1.0 - abs(x) - abs(y)
            let t = max(-z, 0.0)
            x = x >= 0.0 ? x - t : x + t
            y = y >= 0.0 ? y - t : y + t
            let length = sqrt(max(x * x + y * y + z * z, .leastNonzeroMagnitude))
            let axis = SIMD3<Float>(x / length, y / length, z / length)
            let halfTheta = Float(bytes[offset + 2]) / 255.0 * 0.5 * Float.pi
            let s = sin(halfTheta)
            let w = cos(halfTheta)
            result.append(contentsOf: [axis.x * s, axis.y * s, axis.z * s, w])
        }
        return result
    }
}

private func inflate(_ data: Data) throws -> Data {
    do {
        return try inflate(data, windowBits: 32 + MAX_WBITS)
    } catch SplatRADLoaderError.decompressionFailed {
        return try inflate(data, windowBits: -MAX_WBITS)
    }
}

private func inflate(_ data: Data, windowBits: Int32) throws -> Data {
    var stream = z_stream()
    var status = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else {
        throw SplatRADLoaderError.unsupportedCompressedProperty(status)
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    let chunkSize = 64 * 1024
    var chunk = Array(repeating: UInt8(0), count: chunkSize)

    try data.withUnsafeBytes { rawBuffer in
        guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            throw SplatRADLoaderError.invalidChunkMetadata
        }
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source)
        stream.avail_in = uInt(rawBuffer.count)

        repeat {
            chunk.withUnsafeMutableBytes { outputBuffer in
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkSize)
                status = zlib.inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(outputBuffer.bindMemory(to: UInt8.self).baseAddress!, count: produced)
                }
            }
            guard status == Z_OK || status == Z_STREAM_END else {
                throw SplatRADLoaderError.decompressionFailed(status)
            }
        } while status != Z_STREAM_END
    }

    return output
}

private func requireDataByteCount(_ data: Data, _ byteCount: Int) throws {
    guard data.count >= byteCount else { throw SplatRADLoaderError.incompleteHeader }
}

private struct RADMetadataJSON: Decodable {
    var version: Int
    var type: String
    var count: Int
    var maxSH: Int?
    var lodTree: Bool?
    var chunkSize: Int?
    var allChunkBytes: Int?
    var chunks: [RADChunkRangeJSON]
    var splatEncoding: RADSplatEncodingJSON?

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case count
        case maxSH = "maxSh"
        case lodTree
        case chunkSize
        case allChunkBytes
        case chunks
        case splatEncoding
    }
}

private struct RADChunkRangeJSON: Decodable {
    var offset: Int
    var bytes: Int
    var base: Int?
    var count: Int?
    var filename: String?
}

private struct RADSplatEncodingJSON: Decodable {
    var rgbMin: Float?
    var rgbMax: Float?
    var lnScaleMin: Float?
    var lnScaleMax: Float?
    var sh1Max: Float?
    var sh2Max: Float?
    var sh3Max: Float?
    var lodOpacity: Bool?

    var splatEncoding: SplatEncoding {
        SplatEncoding(
            rgbMin: rgbMin ?? 0.0,
            rgbMax: rgbMax ?? 1.0,
            lnScaleMin: lnScaleMin ?? SparkConstants.lnScaleMin,
            lnScaleMax: lnScaleMax ?? SparkConstants.lnScaleMax,
            sh1Max: sh1Max ?? 1.0,
            sh2Max: sh2Max ?? 1.0,
            sh3Max: sh3Max ?? 1.0,
            lodOpacity: lodOpacity ?? false
        )
    }
}

@inline(__always)
private func roundUpToEight(_ size: Int) -> Int {
    (size + 7) & ~7
}

@inline(__always)
private func readLittleUInt32(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

@inline(__always)
private func readLittleUInt16(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

@inline(__always)
private func readLittleUInt64(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt64 {
    var value = UInt64(bytes[offset])
    value |= UInt64(bytes[offset + 1]) << 8
    value |= UInt64(bytes[offset + 2]) << 16
    value |= UInt64(bytes[offset + 3]) << 24
    value |= UInt64(bytes[offset + 4]) << 32
    value |= UInt64(bytes[offset + 5]) << 40
    value |= UInt64(bytes[offset + 6]) << 48
    value |= UInt64(bytes[offset + 7]) << 56
    return value
}

@inline(__always)
private func readFloat32(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> Float {
    Float(bitPattern: readLittleUInt32(bytes, offset: offset))
}
