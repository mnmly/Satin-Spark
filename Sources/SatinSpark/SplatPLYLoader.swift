// PLY decoding conventions (sigmoid opacity, `SH_C0 * f_dc + 0.5` color, alpha
// divisors) are ported from https://github.com/sparkjsdev/spark — `src/ply.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation
import simd

public enum SplatPLYLoaderError: LocalizedError {
    case invalidHeader
    case unsupportedFormat(String)
    case missingVertexElement
    case missingProperty(String)
    case truncatedBody
    case invalidASCIIValue(line: Int, property: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "The file is not a valid PLY file."
        case let .unsupportedFormat(format):
            return "Unsupported PLY format: \(format)."
        case .missingVertexElement:
            return "The PLY file does not contain a vertex element."
        case let .missingProperty(property):
            return "The PLY file is missing required property '\(property)'."
        case .truncatedBody:
            return "The PLY file ended before all vertex data could be read."
        case let .invalidASCIIValue(line, property):
            return "Could not parse property '\(property)' on vertex line \(line)."
        }
    }
}

public enum SplatPLYLoader {
    public static func load(url: URL) throws -> PackedSplats {
        try parse(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func parse(_ data: Data) throws -> PackedSplats {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw SplatPLYLoaderError.invalidHeader
            }
            let header = try parseHeader(base: base, count: rawBuffer.count)
            let layout = try VertexLayout(properties: header.vertexProperties)

            switch header.format {
            case .ascii:
                return try parseASCIIVertices(base: base, count: rawBuffer.count, header: header, layout: layout)
            case .binaryLittleEndian:
                return try parseBinaryLittleEndianVertices(base: base, count: rawBuffer.count, header: header, layout: layout)
            }
        }
    }
}

private enum PLYFormat {
    case ascii
    case binaryLittleEndian
}

private enum PLYScalarType: String {
    case int8
    case uint8
    case int16
    case uint16
    case int32
    case uint32
    case float32
    case float64

    init?(_ raw: String) {
        switch raw {
        case "char", "int8":
            self = .int8
        case "uchar", "uint8":
            self = .uint8
        case "short", "int16":
            self = .int16
        case "ushort", "uint16":
            self = .uint16
        case "int", "int32":
            self = .int32
        case "uint", "uint32":
            self = .uint32
        case "float", "float32":
            self = .float32
        case "double", "float64":
            self = .float64
        default:
            return nil
        }
    }

    var byteCount: Int {
        switch self {
        case .int8, .uint8:
            return 1
        case .int16, .uint16:
            return 2
        case .int32, .uint32, .float32:
            return 4
        case .float64:
            return 8
        }
    }

    var normalizedColorScale: Float {
        switch self {
        case .int8:
            return 127.0
        case .uint8:
            return 255.0
        case .int16:
            return 32767.0
        case .uint16:
            return 65535.0
        case .int32:
            return 2147483647.0
        case .uint32:
            return 4294967295.0
        case .float32, .float64:
            return 1.0
        }
    }
}

private struct PLYProperty {
    var name: String
    var type: PLYScalarType
}

private struct PLYHeader {
    var format: PLYFormat
    var vertexCount: Int
    var vertexProperties: [PLYProperty]
    var bodyOffset: Int
}

private enum VertexSemantic: Equatable {
    case x
    case y
    case z
    case scale0
    case scale1
    case scale2
    case scaleX
    case scaleY
    case scaleZ
    case rot0
    case rot1
    case rot2
    case rot3
    case opacity
    case red
    case green
    case blue
    case alpha
    case fdc0
    case fdc1
    case fdc2
    case fRest(Int)
    case ignored
}

private struct VertexField {
    var semantic: VertexSemantic
    var name: String
    var type: PLYScalarType
    var offset: Int
}

private struct VertexLayout {
    var fields: [VertexField]
    var activeFields: [VertexField]
    var stride: Int
    var redScale: Float = 1.0
    var greenScale: Float = 1.0
    var blueScale: Float = 1.0
    var alphaScale: Float = 1.0
    var shDegree: Int = 0
    var shRestCount: Int = 0

    init(properties: [PLYProperty]) throws {
        var offset = 0
        var fields: [VertexField] = []
        fields.reserveCapacity(properties.count)

        for property in properties {
            let semantic = semantic(for: property.name)
            fields.append(VertexField(semantic: semantic, name: property.name, type: property.type, offset: offset))
            offset += property.type.byteCount

            switch semantic {
            case .red:
                redScale = property.type.normalizedColorScale
            case .green:
                greenScale = property.type.normalizedColorScale
            case .blue:
                blueScale = property.type.normalizedColorScale
            case .alpha:
                alphaScale = property.type.normalizedColorScale
            default:
                break
            }
        }

        shRestCount = fields.reduce(0) { result, field in
            if case let .fRest(index) = field.semantic {
                return max(result, index + 1)
            }
            return result
        }
        switch shRestCount {
        case 0:
            shDegree = 0
        case 9:
            shDegree = 1
        case 24:
            shDegree = 2
        case 45:
            shDegree = 3
        default:
            throw SplatPLYLoaderError.unsupportedFormat("unsupported number of SH coefficients: \(shRestCount)")
        }

        guard fields.contains(where: { $0.semantic == .x }),
              fields.contains(where: { $0.semantic == .y }),
              fields.contains(where: { $0.semantic == .z }) else {
            throw SplatPLYLoaderError.missingProperty("x, y, z")
        }

        self.fields = fields
        activeFields = fields.filter { $0.semantic != .ignored }
        stride = offset
    }
}

private struct VertexValues {
    var x: Float = 0.0
    var y: Float = 0.0
    var z: Float = 0.0
    var scale0: Float?
    var scale1: Float?
    var scale2: Float?
    var scaleX: Float?
    var scaleY: Float?
    var scaleZ: Float?
    var rot0: Float = 1.0
    var rot1: Float = 0.0
    var rot2: Float = 0.0
    var rot3: Float = 0.0
    var opacity: Float?
    var red: Float?
    var green: Float?
    var blue: Float?
    var alpha: Float?
    var fdc0: Float?
    var fdc1: Float?
    var fdc2: Float?
    var fRest = Array(repeating: Float(0.0), count: 45)
}

private let shC0: Float = 0.28209479177387814
private let defaultPointScale: Float = 0.001
private let defaultEncoding = SplatEncoding()

private func parseHeader(base: UnsafePointer<UInt8>, count: Int) throws -> PLYHeader {
    guard count >= 4, base[0] == 0x70, base[1] == 0x6c, base[2] == 0x79 else {
        throw SplatPLYLoaderError.invalidHeader
    }

    var cursor = 0
    var format: PLYFormat?
    var currentElement: String?
    var vertexCount: Int?
    var vertexProperties: [PLYProperty] = []

    while cursor < count {
        let lineStart = cursor
        while cursor < count, base[cursor] != 0x0a {
            cursor += 1
        }
        let lineEnd = cursor > lineStart && base[cursor - 1] == 0x0d ? cursor - 1 : cursor
        if cursor < count {
            cursor += 1
        }

        let line = String(decoding: UnsafeBufferPointer(start: base + lineStart, count: lineEnd - lineStart), as: UTF8.self)
        let parts = line.split(separator: " ").map(String.init)
        guard let first = parts.first else { continue }

        switch first {
        case "format":
            guard parts.count >= 2 else { throw SplatPLYLoaderError.invalidHeader }
            switch parts[1] {
            case "ascii":
                format = .ascii
            case "binary_little_endian":
                format = .binaryLittleEndian
            default:
                throw SplatPLYLoaderError.unsupportedFormat(parts[1])
            }
        case "element":
            guard parts.count >= 3 else { throw SplatPLYLoaderError.invalidHeader }
            currentElement = parts[1]
            if parts[1] == "vertex" {
                vertexCount = Int(parts[2])
            }
        case "property":
            guard currentElement == "vertex", parts.count >= 3 else { continue }
            if parts[1] == "list" {
                throw SplatPLYLoaderError.unsupportedFormat("list properties in vertex elements")
            }
            guard let type = PLYScalarType(parts[1]) else {
                throw SplatPLYLoaderError.unsupportedFormat("property type \(parts[1])")
            }
            vertexProperties.append(PLYProperty(name: parts[2], type: type))
        case "end_header":
            guard let format, let vertexCount else { throw SplatPLYLoaderError.missingVertexElement }
            return PLYHeader(
                format: format,
                vertexCount: vertexCount,
                vertexProperties: vertexProperties,
                bodyOffset: cursor
            )
        default:
            continue
        }
    }

    throw SplatPLYLoaderError.invalidHeader
}

private func parseBinaryLittleEndianVertices(
    base: UnsafePointer<UInt8>,
    count: Int,
    header: PLYHeader,
    layout: VertexLayout
) throws -> PackedSplats {
    let bodyByteCount = header.vertexCount * layout.stride
    guard header.bodyOffset + bodyByteCount <= count else {
        throw SplatPLYLoaderError.truncatedBody
    }

    var packedArray = Array(repeating: UInt32(0), count: header.vertexCount * 4)
    var sphericalHarmonics = makeSphericalHarmonicsStorage(numSplats: header.vertexCount, degree: layout.shDegree)
    for index in 0 ..< header.vertexCount {
        let vertexBase = base + header.bodyOffset + index * layout.stride
        let values = readBinaryVertex(base: vertexBase, layout: layout)
        writePackedSplat(values, layout: layout, into: &packedArray, at: index)
        writeSphericalHarmonics(values, layout: layout, into: &sphericalHarmonics, at: index)
    }

    return PackedSplats(packedArray: packedArray, numSplats: header.vertexCount, sphericalHarmonics: sphericalHarmonics)
}

private func parseASCIIVertices(
    base: UnsafePointer<UInt8>,
    count: Int,
    header: PLYHeader,
    layout: VertexLayout
) throws -> PackedSplats {
    var cursor = header.bodyOffset
    var packedArray = Array(repeating: UInt32(0), count: header.vertexCount * 4)
    var sphericalHarmonics = makeSphericalHarmonicsStorage(numSplats: header.vertexCount, degree: layout.shDegree)

    for index in 0 ..< header.vertexCount {
        while cursor < count, (base[cursor] == 0x0a || base[cursor] == 0x0d) {
            cursor += 1
        }
        guard cursor < count else {
            throw SplatPLYLoaderError.truncatedBody
        }

        let lineStart = cursor
        while cursor < count, base[cursor] != 0x0a {
            cursor += 1
        }
        let lineEnd = cursor > lineStart && base[cursor - 1] == 0x0d ? cursor - 1 : cursor
        if cursor < count {
            cursor += 1
        }

        let line = String(decoding: UnsafeBufferPointer(start: base + lineStart, count: lineEnd - lineStart), as: UTF8.self)
        let columns = line.split(separator: " ")
        guard columns.count >= layout.fields.count else {
            throw SplatPLYLoaderError.truncatedBody
        }

        var values = VertexValues()
        for (fieldIndex, field) in layout.fields.enumerated() {
            guard field.semantic != .ignored else { continue }
            guard let value = Float(columns[fieldIndex]) else {
                throw SplatPLYLoaderError.invalidASCIIValue(line: index + 1, property: field.name)
            }
            assign(value, semantic: field.semantic, to: &values)
        }
        writePackedSplat(values, layout: layout, into: &packedArray, at: index)
        writeSphericalHarmonics(values, layout: layout, into: &sphericalHarmonics, at: index)
    }

    return PackedSplats(packedArray: packedArray, numSplats: header.vertexCount, sphericalHarmonics: sphericalHarmonics)
}

private func readBinaryVertex(base: UnsafePointer<UInt8>, layout: VertexLayout) -> VertexValues {
    var values = VertexValues()
    for field in layout.activeFields {
        let value = readScalar(type: field.type, base: base + field.offset)
        assign(value, semantic: field.semantic, to: &values)
    }
    return values
}

private func writePackedSplat(_ values: VertexValues, layout: VertexLayout, into packedArray: inout [UInt32], at index: Int) {
    let scale = SIMD3<Float>(
        decodedScale(logScale: values.scale0, directScale: values.scaleX),
        decodedScale(logScale: values.scale1, directScale: values.scaleY),
        decodedScale(logScale: values.scale2, directScale: values.scaleZ)
    )
    let rotation = normalizedQuaternion(
        r: values.rot0,
        i: values.rot1,
        j: values.rot2,
        k: values.rot3
    )
    let color = splatColor(values, layout: layout)
    let opacity = splatOpacity(values, layout: layout)
    let encodedQuat = encodeQuatOctXy88R8(rotation)
    let offset = index * 4

    packedArray[offset + 0] = packedRGBAWord(color: color, opacity: opacity, encoding: defaultEncoding)
    packedArray[offset + 1] = UInt32(Float16(finiteOrZero(values.x)).bitPattern)
        | (UInt32(Float16(finiteOrZero(values.y)).bitPattern) << 16)
    packedArray[offset + 2] = UInt32(Float16(finiteOrZero(values.z)).bitPattern)
        | ((encodedQuat & 0xff) << 16)
        | (((encodedQuat >> 8) & 0xff) << 24)
    packedArray[offset + 3] = encodePackedScale(scale.x, encoding: defaultEncoding)
        | (encodePackedScale(scale.y, encoding: defaultEncoding) << 8)
        | (encodePackedScale(scale.z, encoding: defaultEncoding) << 16)
        | (((encodedQuat >> 16) & 0xff) << 24)
}

private func makeSphericalHarmonicsStorage(numSplats: Int, degree: Int) -> PackedSphericalHarmonics {
    PackedSphericalHarmonics.storage(numSplats: numSplats, degree: degree)
}

private func writeSphericalHarmonics(
    _ values: VertexValues,
    layout: VertexLayout,
    into sphericalHarmonics: inout PackedSphericalHarmonics,
    at index: Int
) {
    guard layout.shDegree > 0 else { return }
    let shRestCount = layout.shRestCount
    if sphericalHarmonics.sh1 != nil {
        let coefficients = shCoefficients(values.fRest, start: 0, count: 3, shRestCount: shRestCount)
        sphericalHarmonics.setSH1(coefficients, at: index, encoding: defaultEncoding)
    }
    if sphericalHarmonics.sh2 != nil {
        let coefficients = shCoefficients(values.fRest, start: 3, count: 5, shRestCount: shRestCount)
        sphericalHarmonics.setSH2(coefficients, at: index, encoding: defaultEncoding)
    }
    if sphericalHarmonics.sh3 != nil {
        let coefficients = shCoefficients(values.fRest, start: 8, count: 7, shRestCount: shRestCount)
        sphericalHarmonics.setSH3(coefficients, at: index, encoding: defaultEncoding)
    }
}

private func shCoefficients(_ fRest: [Float], start: Int, count: Int, shRestCount: Int) -> [Float] {
    var coefficients = Array(repeating: Float(0.0), count: count * 3)
    let stride = shRestCount / 3
    for k in 0 ..< count {
        for d in 0 ..< 3 {
            let source = start + k + d * stride
            coefficients[k * 3 + d] = source < fRest.count ? fRest[source] : 0.0
        }
    }
    return coefficients
}

private func decodedScale(logScale: Float?, directScale: Float?) -> Float {
    if let logScale {
        let scale = exp(logScale)
        return scale.isFinite ? scale : 0.0
    }
    if let directScale {
        return directScale.isFinite ? directScale : 0.0
    }
    return defaultPointScale
}

private func splatColor(_ values: VertexValues, layout: VertexLayout) -> SIMD3<Float> {
    if let red = values.red, let green = values.green, let blue = values.blue {
        return SIMD3<Float>(
            clamp01(red / layout.redScale),
            clamp01(green / layout.greenScale),
            clamp01(blue / layout.blueScale)
        )
    }
    return SIMD3<Float>(
        clamp01(0.5 + shC0 * (values.fdc0 ?? 0.0)),
        clamp01(0.5 + shC0 * (values.fdc1 ?? 0.0)),
        clamp01(0.5 + shC0 * (values.fdc2 ?? 0.0))
    )
}

private func splatOpacity(_ values: VertexValues, layout: VertexLayout) -> Float {
    if let opacity = values.opacity {
        return clamp01(1.0 / (1.0 + exp(-opacity)))
    }
    if let alpha = values.alpha {
        return clamp01(alpha / layout.alphaScale)
    }
    return 1.0
}

private func normalizedQuaternion(r: Float, i: Float, j: Float, k: Float) -> simd_quatf {
    let length = sqrt(r * r + i * i + j * j + k * k)
    guard length.isFinite, length > 0.0 else {
        return simd_quatf(angle: 0.0, axis: [1.0, 0.0, 0.0])
    }
    return simd_normalize(simd_quatf(ix: i / length, iy: j / length, iz: k / length, r: r / length))
}

private func assign(_ value: Float, semantic: VertexSemantic, to values: inout VertexValues) {
    switch semantic {
    case .x:
        values.x = value
    case .y:
        values.y = value
    case .z:
        values.z = value
    case .scale0:
        values.scale0 = value
    case .scale1:
        values.scale1 = value
    case .scale2:
        values.scale2 = value
    case .scaleX:
        values.scaleX = value
    case .scaleY:
        values.scaleY = value
    case .scaleZ:
        values.scaleZ = value
    case .rot0:
        values.rot0 = value
    case .rot1:
        values.rot1 = value
    case .rot2:
        values.rot2 = value
    case .rot3:
        values.rot3 = value
    case .opacity:
        values.opacity = value
    case .red:
        values.red = value
    case .green:
        values.green = value
    case .blue:
        values.blue = value
    case .alpha:
        values.alpha = value
    case .fdc0:
        values.fdc0 = value
    case .fdc1:
        values.fdc1 = value
    case .fdc2:
        values.fdc2 = value
    case let .fRest(index):
        if index >= 0, index < values.fRest.count {
            values.fRest[index] = value
        }
    case .ignored:
        break
    }
}

private func semantic(for name: String) -> VertexSemantic {
    if name.hasPrefix("f_rest_"), let index = Int(name.dropFirst("f_rest_".count)) {
        return .fRest(index)
    }
    switch name {
    case "x":
        return .x
    case "y":
        return .y
    case "z":
        return .z
    case "scale_0":
        return .scale0
    case "scale_1":
        return .scale1
    case "scale_2":
        return .scale2
    case "sx", "scale_x":
        return .scaleX
    case "sy", "scale_y":
        return .scaleY
    case "sz", "scale_z":
        return .scaleZ
    case "rot_0":
        return .rot0
    case "rot_1":
        return .rot1
    case "rot_2":
        return .rot2
    case "rot_3":
        return .rot3
    case "opacity":
        return .opacity
    case "red":
        return .red
    case "green":
        return .green
    case "blue":
        return .blue
    case "alpha":
        return .alpha
    case "f_dc_0":
        return .fdc0
    case "f_dc_1":
        return .fdc1
    case "f_dc_2":
        return .fdc2
    default:
        return .ignored
    }
}

private func readScalar(type: PLYScalarType, base: UnsafePointer<UInt8>) -> Float {
    switch type {
    case .int8:
        return Float(Int8(bitPattern: base[0]))
    case .uint8:
        return Float(base[0])
    case .int16:
        return Float(Int16(littleEndian: loadUnaligned(base)))
    case .uint16:
        return Float(UInt16(littleEndian: loadUnaligned(base)))
    case .int32:
        return Float(Int32(littleEndian: loadUnaligned(base)))
    case .uint32:
        return Float(UInt32(littleEndian: loadUnaligned(base)))
    case .float32:
        return Float(bitPattern: UInt32(littleEndian: loadUnaligned(base)))
    case .float64:
        return Float(Double(bitPattern: UInt64(littleEndian: loadUnaligned(base))))
    }
}

private func loadUnaligned<T: FixedWidthInteger>(_ base: UnsafePointer<UInt8>) -> T {
    var value: T = 0
    for offset in 0 ..< MemoryLayout<T>.size {
        value |= T(base[offset]) << T(offset * 8)
    }
    return value
}
