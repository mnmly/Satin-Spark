import Foundation
import simd

public enum SplatFixtures {
    public static func deterministicScene() -> PackedSplats {
        let splats: [PackedSplat] = [
            PackedSplat(
                center: [-0.72, -0.24, 0.0],
                scale: [0.072, 0.032, 0.032],
                rotation: simd_quatf(angle: 0.55, axis: [0.0, 0.0, 1.0]),
                opacity: 0.72,
                color: [1.0, 0.18, 0.12]
            ),
            PackedSplat(
                center: [-0.22, 0.20, -0.18],
                scale: [0.048, 0.072, 0.040],
                rotation: simd_quatf(angle: -0.35, axis: [0.0, 0.0, 1.0]),
                opacity: 0.65,
                color: [0.18, 0.78, 1.0]
            ),
            PackedSplat(
                center: [0.28, -0.18, 0.12],
                scale: [0.064, 0.044, 0.056],
                rotation: simd_quatf(angle: 0.95, axis: normalize(SIMD3<Float>(0.4, 0.7, 0.2))),
                opacity: 0.60,
                color: [1.0, 0.78, 0.12]
            ),
            PackedSplat(
                center: [0.70, 0.22, -0.05],
                scale: [0.040, 0.080, 0.036],
                rotation: simd_quatf(angle: 0.25, axis: [1.0, 0.0, 0.0]),
                opacity: 0.58,
                color: [0.42, 1.0, 0.36]
            ),
            PackedSplat(
                center: [0.0, 0.0, 0.28],
                scale: [0.088, 0.088, 0.088],
                opacity: 0.34,
                color: [0.88, 0.52, 1.0]
            ),
        ]
        return PackedSplats(splats: splats)
    }
}
