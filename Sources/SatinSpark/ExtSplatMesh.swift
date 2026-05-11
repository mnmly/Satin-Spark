import Metal
import Satin

open class ExtSplatMesh: Mesh {
    public private(set) var extSplats: ExtSplats
    public private(set) var arrayABuffer: MTLBuffer?
    public private(set) var arrayBBuffer: MTLBuffer?
    public private(set) var orderingBuffer: MTLBuffer?
    public private(set) var ordering: [UInt32] = []

    public init(
        context: Context,
        extSplats: ExtSplats,
        liveShader: Bool = false
    ) {
        self.extSplats = extSplats
        let material = ExtSplatMaterial(context: context, live: liveShader)
        super.init(
            context: context,
            label: "ExtSplatMesh",
            geometry: SplatGeometry(context: context),
            material: material,
            renderLayer: .opaque
        )
        castShadow = false
        receiveShadow = false
        doubleSided = true
        cullMode = .none
        instanceCount = extSplats.numSplats
        rebuildBuffers()
    }

    public required init(from decoder: any Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }

    public func replaceExtSplats(_ extSplats: ExtSplats) {
        self.extSplats = extSplats
        instanceCount = extSplats.numSplats
        rebuildBuffers()
    }

    public func rebuildBuffers() {
        arrayABuffer = extSplats.makeBufferA(device: context.device)
        arrayBBuffer = extSplats.makeBufferB(device: context.device)
        ordering = (0 ..< extSplats.numSplats).map(UInt32.init)
        orderingBuffer = extSplats.toPackedSplats().makeOrderingBuffer(device: context.device, ordering: ordering)
        bindSplatBuffers()
    }

    public func applyOrdering(_ ordering: [UInt32]) {
        guard ordering.count == extSplats.numSplats else { return }
        self.ordering = ordering
        let byteCount = ordering.count * MemoryLayout<UInt32>.stride
        if let orderingBuffer, orderingBuffer.length >= byteCount {
            ordering.withUnsafeBytes { bytes in
                orderingBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
            }
        } else {
            orderingBuffer = extSplats.toPackedSplats().makeOrderingBuffer(device: context.device, ordering: ordering)
            bindSplatBuffers()
        }
    }

    open override func setupMaterial() {
        super.setupMaterial()
        bindSplatBuffers()
    }

    private func bindSplatBuffers() {
        guard let material = material as? ExtSplatMaterial else { return }
        material.setExtBuffers(arrayA: arrayABuffer, arrayB: arrayBBuffer)
        material.setOrderingBuffer(orderingBuffer)
        material.numSplats = UInt32(extSplats.numSplats)
    }
}
