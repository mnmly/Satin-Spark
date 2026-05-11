// Skinning math is ported from https://github.com/sparkjsdev/spark —
// `src/SplatSkinning.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.

import Foundation
import simd

public enum SplatSkinningMode: Sendable, Equatable {
    case dualQuaternion
}

public struct SplatBonePose: Sendable, Equatable {
    public var rotation: simd_quatf
    public var position: SIMD3<Float>

    public init(
        rotation: simd_quatf = simd_quatf(angle: 0.0, axis: [1.0, 0.0, 0.0]),
        position: SIMD3<Float> = .zero
    ) {
        self.rotation = rotation
        self.position = position
    }
}

public struct SplatSkinInfluence: Sendable, Equatable {
    public var boneIndices: SIMD4<UInt8>
    public var weights: SIMD4<Float>

    public init(
        boneIndices: SIMD4<UInt8> = SIMD4<UInt8>(repeating: 0),
        weights: SIMD4<Float> = [1.0, 0.0, 0.0, 0.0]
    ) {
        self.boneIndices = boneIndices
        self.weights = weights
    }

    public var packedWords: SIMD4<UInt16> {
        SIMD4<UInt16>(
            pack(index: boneIndices.x, weight: weights.x),
            pack(index: boneIndices.y, weight: weights.y),
            pack(index: boneIndices.z, weight: weights.z),
            pack(index: boneIndices.w, weight: weights.w)
        )
    }

    private func pack(index: UInt8, weight: Float) -> UInt16 {
        let quantized = UInt16(min(max(round(clamp01(weight) * 255.0), 0.0), 255.0))
        return quantized | (UInt16(index) << 8)
    }
}

public struct CovarianceSplat: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var covariance: simd_float3x3
    public var opacity: Float
    public var color: SIMD3<Float>

    public init(center: SIMD3<Float>, covariance: simd_float3x3, opacity: Float, color: SIMD3<Float>) {
        self.center = center
        self.covariance = covariance
        self.opacity = opacity
        self.color = color
    }
}

public final class SplatSkinning {
    public let mode: SplatSkinningMode = .dualQuaternion
    public let numBones: Int
    public private(set) var restPoses: [SplatBonePose]
    public private(set) var boneData: [Float]
    public private(set) var influences: [SplatSkinInfluence]

    public init(numSplats: Int, numBones: Int = 256) {
        precondition(numBones > 0 && numBones <= 256, "SplatSkinning supports 1...256 bones")
        self.numBones = numBones
        self.restPoses = Array(repeating: SplatBonePose(), count: numBones)
        self.boneData = Array(repeating: 0.0, count: numBones * 8)
        self.influences = Array(repeating: SplatSkinInfluence(), count: numSplats)
        for bone in 0 ..< numBones {
            setRestPose(bone, pose: SplatBonePose())
        }
    }

    public func setRestPose(_ boneIndex: Int, pose: SplatBonePose) {
        precondition(boneIndex >= 0 && boneIndex < numBones, "Bone index out of range")
        restPoses[boneIndex] = pose
        setBonePose(boneIndex, pose: pose)
    }

    public func setBonePose(_ boneIndex: Int, pose: SplatBonePose) {
        precondition(boneIndex >= 0 && boneIndex < numBones, "Bone index out of range")
        let rest = restPoses[boneIndex]
        let relativeRotation = simd_normalize(simd_inverse(rest.rotation) * pose.rotation)
        let relativePosition = pose.position - rest.position
        let dual = 0.5 * quaternionMultiply(
            SIMD4<Float>(relativePosition, 0.0),
            relativeRotation.vector
        )
        let offset = boneIndex * 8
        boneData[offset + 0] = relativeRotation.vector.x
        boneData[offset + 1] = relativeRotation.vector.y
        boneData[offset + 2] = relativeRotation.vector.z
        boneData[offset + 3] = relativeRotation.vector.w
        boneData[offset + 4] = dual.x
        boneData[offset + 5] = dual.y
        boneData[offset + 6] = dual.z
        boneData[offset + 7] = dual.w
    }

    public func setSplatBones(_ splatIndex: Int, boneIndices: SIMD4<UInt8>, weights: SIMD4<Float>) {
        precondition(splatIndex >= 0 && splatIndex < influences.count, "Splat index out of range")
        influences[splatIndex] = SplatSkinInfluence(boneIndices: boneIndices, weights: weights)
    }

    public func modify(_ splat: PackedSplat, at index: Int) -> PackedSplat {
        let transform = blendedDualQuaternion(for: index)
        return PackedSplat(
            center: transformPoint(splat.center, by: transform),
            scale: splat.scale,
            rotation: simd_quatf(vector: transform.real) * splat.rotation,
            opacity: splat.opacity,
            color: splat.color
        )
    }

    public func modify(_ splat: ExtSplat, at index: Int) -> ExtSplat {
        let transformed = modify(splat.packedSplat, at: index)
        return ExtSplat(
            center: transformed.center,
            scale: transformed.scale,
            rotation: transformed.rotation,
            opacity: transformed.opacity,
            color: transformed.color
        )
    }

    public func modify(_ splat: CovarianceSplat, at index: Int) -> CovarianceSplat {
        let transform = blendedDualQuaternion(for: index)
        let rotationMatrix = simd_float3x3(simd_quatf(vector: transform.real))
        return CovarianceSplat(
            center: transformPoint(splat.center, by: transform),
            covariance: rotationMatrix * splat.covariance * rotationMatrix.transpose,
            opacity: splat.opacity,
            color: splat.color
        )
    }

    public func apply(to packedSplats: PackedSplats) -> PackedSplats {
        var transformed: [PackedSplat] = []
        transformed.reserveCapacity(packedSplats.numSplats)
        packedSplats.forEachSplat { index, splat in
            transformed.append(modify(splat, at: index))
        }
        return PackedSplats(splats: transformed, splatEncoding: packedSplats.splatEncoding)
    }

    public func apply(to extSplats: ExtSplats) -> ExtSplats {
        var transformed: [ExtSplat] = []
        transformed.reserveCapacity(extSplats.numSplats)
        extSplats.forEachSplat { index, splat in
            transformed.append(modify(splat, at: index))
        }
        return ExtSplats(splats: transformed)
    }

    private func blendedDualQuaternion(for splatIndex: Int) -> (real: SIMD4<Float>, dual: SIMD4<Float>) {
        guard splatIndex >= 0, splatIndex < influences.count else {
            return (SIMD4<Float>(0.0, 0.0, 0.0, 1.0), .zero)
        }

        let influence = influences[splatIndex]
        var real = SIMD4<Float>(repeating: 0.0)
        var dual = SIMD4<Float>(repeating: 0.0)
        for slot in 0 ..< 4 {
            let weight = influence.weights[slot]
            guard weight > 0.0 else { continue }
            let boneIndex = Int(influence.boneIndices[slot])
            guard boneIndex < numBones else { continue }

            let offset = boneIndex * 8
            var boneReal = SIMD4<Float>(
                boneData[offset + 0],
                boneData[offset + 1],
                boneData[offset + 2],
                boneData[offset + 3]
            )
            var boneDual = SIMD4<Float>(
                boneData[offset + 4],
                boneData[offset + 5],
                boneData[offset + 6],
                boneData[offset + 7]
            )
            if simd_length_squared(real) > 0.0, simd_dot(real, boneReal) < 0.0 {
                boneReal = -boneReal
                boneDual = -boneDual
            }
            real += weight * boneReal
            dual += weight * boneDual
        }

        let norm = max(simd_length(real), .leastNonzeroMagnitude)
        return (real / norm, dual / norm)
    }

    private func transformPoint(_ point: SIMD3<Float>, by dualQuaternion: (real: SIMD4<Float>, dual: SIMD4<Float>)) -> SIMD3<Float> {
        let real = dualQuaternion.real
        let dual = dualQuaternion.dual
        let translation = SIMD3<Float>(
            2.0 * (-dual.w * real.x + dual.x * real.w - dual.y * real.z + dual.z * real.y),
            2.0 * (-dual.w * real.y + dual.x * real.z + dual.y * real.w - dual.z * real.x),
            2.0 * (-dual.w * real.z - dual.x * real.y + dual.y * real.x + dual.z * real.w)
        )
        return simd_quatf(vector: real).act(point) + translation
    }
}

private func quaternionMultiply(_ lhs: SIMD4<Float>, _ rhs: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4<Float>(
        lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
        lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
        lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z
    )
}
