import Metal
import Satin
import simd

public final class ExtSplatMaterial: SourceMaterial {
    public override var lightingModel: LightingModel { .unlit }

    public var maxStdDev: Float = sqrt(8.0) { didSet { set("maxStdDev", maxStdDev) } }
    public var minPixelRadius: Float = 0.0 { didSet { set("minPixelRadius", minPixelRadius) } }
    public var maxPixelRadius: Float = 512.0 { didSet { set("maxPixelRadius", maxPixelRadius) } }
    public var minAlpha: Float = 0.5 / 255.0 { didSet { set("minAlpha", minAlpha) } }
    public var preBlurAmount: Float = 0.0 { didSet { set("preBlurAmount", preBlurAmount) } }
    public var blurAmount: Float = 0.3 { didSet { set("blurAmount", blurAmount) } }
    public var clipXY: Float = 1.4 { didSet { set("clipXY", clipXY) } }
    public var focalAdjustment: Float = 1.0 { didSet { set("focalAdjustment", focalAdjustment) } }
    public var falloff: Float = 1.0 { didSet { set("falloff", falloff) } }
    public var renderSize: SIMD2<Float> = [1.0, 1.0] { didSet { set("renderSize", renderSize) } }
    public var numSplats: UInt32 = 0 { didSet { set("numSplats", numSplats) } }

    public init(context: Context, live: Bool = false) {
        let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: "Pipelines/ExtSplat")!
        super.init(context: context, pipelineURL: url, live: live)
        label = "ExtSplat"
        lighting = false
        castShadow = false
        receiveShadow = false
        blending = .alpha
        depthWriteEnabled = false
        depthCompareFunction = .greaterEqual
        applyUniformValues()
    }

    public required convenience init(context: Context) {
        self.init(context: context, live: false)
    }

    public required init(from decoder: any Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }

    public func setExtBuffers(arrayA: MTLBuffer?, arrayB: MTLBuffer?) {
        set(arrayA, index: VertexBufferIndex.Custom0)
        set(arrayB, index: VertexBufferIndex.Custom1)
        updateExplicitBufferBindings()
    }

    public func setOrderingBuffer(_ buffer: MTLBuffer?) {
        set(buffer, index: VertexBufferIndex.Custom2)
        updateExplicitBufferBindings()
    }

    public override func updateShader() {
        super.updateShader()
        applyUniformValues()
    }

    private func applyUniformValues() {
        set("maxStdDev", maxStdDev)
        set("minPixelRadius", minPixelRadius)
        set("maxPixelRadius", maxPixelRadius)
        set("minAlpha", minAlpha)
        set("preBlurAmount", preBlurAmount)
        set("blurAmount", blurAmount)
        set("clipXY", clipXY)
        set("focalAdjustment", focalAdjustment)
        set("falloff", falloff)
        set("renderSize", renderSize)
        set("numSplats", numSplats)
    }

    private func updateExplicitBufferBindings() {
        let arrayA = vertexBuffers[.Custom0]
        let arrayB = vertexBuffers[.Custom1]
        let ordering = vertexBuffers[.Custom2]
        onBind = { renderEncoder in
            if let arrayA {
                renderEncoder.setVertexBuffer(arrayA, offset: 0, index: VertexBufferIndex.Custom0.rawValue)
            }
            if let arrayB {
                renderEncoder.setVertexBuffer(arrayB, offset: 0, index: VertexBufferIndex.Custom1.rawValue)
            }
            if let ordering {
                renderEncoder.setVertexBuffer(ordering, offset: 0, index: VertexBufferIndex.Custom2.rawValue)
            }
        }
    }
}
