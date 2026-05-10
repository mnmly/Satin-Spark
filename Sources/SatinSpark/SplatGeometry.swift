import Metal
import Satin
import simd

public final class SplatGeometry: Geometry {
    private var indices: [UInt16] = [0, 1, 2, 0, 2, 3]
    private let positions = Float3BufferAttribute(defaultValue: .zero, data: [
        SIMD3<Float>(-1.0, -1.0, 0.0),
        SIMD3<Float>(1.0, -1.0, 0.0),
        SIMD3<Float>(1.0, 1.0, 0.0),
        SIMD3<Float>(-1.0, 1.0, 0.0),
    ])

    public init(context: Context) {
        super.init(context: context, primitiveType: .triangle)
        addAttribute(positions, for: .Position)
        setElements(ElementBuffer(type: .uint16, data: &indices, count: indices.count, source: indices))
    }
}
