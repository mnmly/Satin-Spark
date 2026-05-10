import Foundation
import simd

func writePackedSplatWords(
    center: SIMD3<Float>,
    scale: SIMD3<Float>,
    rotation: simd_quatf,
    color: SIMD3<Float>,
    opacity: Float,
    encoding: SplatEncoding,
    into packedArray: inout [UInt32],
    at index: Int
) {
    let encodedQuat = encodeQuatOctXy88R8(rotation)
    let offset = index * 4

    packedArray[offset + 0] = packedRGBAWord(color: color, opacity: opacity, encoding: encoding)
    packedArray[offset + 1] = UInt32(Float16(finiteOrZero(center.x)).bitPattern)
        | (UInt32(Float16(finiteOrZero(center.y)).bitPattern) << 16)
    packedArray[offset + 2] = UInt32(Float16(finiteOrZero(center.z)).bitPattern)
        | ((encodedQuat & 0xff) << 16)
        | (((encodedQuat >> 8) & 0xff) << 24)
    packedArray[offset + 3] = encodePackedScale(scale.x, encoding: encoding)
        | (encodePackedScale(scale.y, encoding: encoding) << 8)
        | (encodePackedScale(scale.z, encoding: encoding) << 16)
        | (((encodedQuat >> 16) & 0xff) << 24)
}

func normalizedPackedQuaternion(r: Float, i: Float, j: Float, k: Float) -> simd_quatf {
    let length = sqrt(r * r + i * i + j * j + k * k)
    guard length.isFinite, length > 0.0 else {
        return simd_quatf(angle: 0.0, axis: [1.0, 0.0, 0.0])
    }
    return simd_normalize(simd_quatf(ix: i / length, iy: j / length, iz: k / length, r: r / length))
}
