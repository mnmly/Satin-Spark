import Metal
import Satin
import simd

public final class SplatMaterial: SourceMaterial {
    public override var lightingModel: LightingModel { .unlit }

    public var maxStdDev: Float = sqrt(8.0) {
        didSet { set("maxStdDev", maxStdDev) }
    }

    public var minPixelRadius: Float = 0.0 {
        didSet { set("minPixelRadius", minPixelRadius) }
    }

    public var maxPixelRadius: Float = 512.0 {
        didSet { set("maxPixelRadius", maxPixelRadius) }
    }

    public var minAlpha: Float = 0.5 / 255.0 {
        didSet { set("minAlpha", minAlpha) }
    }

    public var preBlurAmount: Float = 0.0 {
        didSet { set("preBlurAmount", preBlurAmount) }
    }

    public var blurAmount: Float = 0.3 {
        didSet { set("blurAmount", blurAmount) }
    }

    public var clipXY: Float = 1.4 {
        didSet { set("clipXY", clipXY) }
    }

    public var focalAdjustment: Float = 1.0 {
        didSet { set("focalAdjustment", focalAdjustment) }
    }

    public var falloff: Float = 1.0 {
        didSet { set("falloff", falloff) }
    }

    public var renderSize: SIMD2<Float> = [1.0, 1.0] {
        didSet { set("renderSize", renderSize) }
    }

    public var debugMode: UInt32 = 0 {
        didSet { set("debugMode", debugMode) }
    }

    public var shDegree: UInt32 = 0 {
        didSet { set("shDegree", shDegree) }
    }

    public var lodOpacity: Bool = false {
        didSet { set("lodOpacity", lodOpacity ? UInt32(1) : UInt32(0)) }
    }

    /// When true, render in byte-parity mode with three.js Spark's WebGL fixture:
    /// - skip the `rgba.a *= 2.0` opacity doubling in vertex
    /// - skip the `srgbToLinear` decode in fragment
    /// Use together with a non-sRGB render target (.bgra8Unorm) and an sRGB-encoded
    /// clear color so the alpha blend math operates in the same display-space the
    /// browser fixture does.
    public var legacySparkBlending: Bool = false {
        didSet { set("legacySparkBlending", legacySparkBlending ? UInt32(1) : UInt32(0)) }
    }

    private var numSplats: UInt32 = 0

    public var splatEncoding: SplatEncoding = SplatEncoding() {
        didSet { updateEncodingUniform() }
    }

    public init(context: Context, live: Bool = false) {
        let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: "Pipelines/Splat")!
        super.init(context: context, pipelineURL: url, live: live)
        label = "Splat"
        lighting = false
        castShadow = false
        receiveShadow = false
        blending = .alpha
        depthWriteEnabled = false
        depthCompareFunction = .greaterEqual
        setDefaults()
    }

    public required convenience init(context: Context) {
        self.init(context: context, live: false)
    }

    public required init(from decoder: any Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }

    public func setPackedBuffer(_ buffer: MTLBuffer?) {
        set(buffer, index: VertexBufferIndex.Custom0)
        updateExplicitBufferBindings()
    }

    public func setOrderingBuffer(_ buffer: MTLBuffer?) {
        set(buffer, index: VertexBufferIndex.Custom1)
        updateExplicitBufferBindings()
    }

    public func setSHBuffers(sh1: MTLBuffer?, sh2: MTLBuffer?, sh3: MTLBuffer?) {
        set(sh1, index: VertexBufferIndex.Custom2)
        set(sh2, index: VertexBufferIndex.Custom3)
        set(sh3, index: VertexBufferIndex.Custom4)
        updateExplicitBufferBindings()
    }

    public func setNumSplats(_ numSplats: Int) {
        self.numSplats = UInt32(numSplats)
        set("numSplats", self.numSplats)
    }

    private func setDefaults() {
        applyUniformValues()
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
        set("debugMode", debugMode)
        set("shDegree", shDegree)
        set("lodOpacity", lodOpacity ? UInt32(1) : UInt32(0))
        set("legacySparkBlending", legacySparkBlending ? UInt32(1) : UInt32(0))
        updateEncodingUniform()
    }

    private func updateEncodingUniform() {
        set(
            "rgbMinMaxLnScaleMinMax",
            SIMD4<Float>(
                splatEncoding.rgbMin,
                splatEncoding.rgbMax,
                splatEncoding.lnScaleMin,
                splatEncoding.lnScaleMax
            )
        )
        set("shMax", SIMD3<Float>(splatEncoding.sh1Max, splatEncoding.sh2Max, splatEncoding.sh3Max))
        lodOpacity = splatEncoding.lodOpacity
    }

    private func updateExplicitBufferBindings() {
        let packed = vertexBuffers[.Custom0]
        let ordering = vertexBuffers[.Custom1]
        let sh1 = vertexBuffers[.Custom2]
        let sh2 = vertexBuffers[.Custom3]
        let sh3 = vertexBuffers[.Custom4]
        onBind = { renderEncoder in
            if let packed {
                renderEncoder.setVertexBuffer(packed, offset: 0, index: VertexBufferIndex.Custom0.rawValue)
            }
            if let ordering {
                renderEncoder.setVertexBuffer(ordering, offset: 0, index: VertexBufferIndex.Custom1.rawValue)
            }
            if let sh1 {
                renderEncoder.setVertexBuffer(sh1, offset: 0, index: VertexBufferIndex.Custom2.rawValue)
            }
            if let sh2 {
                renderEncoder.setVertexBuffer(sh2, offset: 0, index: VertexBufferIndex.Custom3.rawValue)
            }
            if let sh3 {
                renderEncoder.setVertexBuffer(sh3, offset: 0, index: VertexBufferIndex.Custom4.rawValue)
            }
        }
    }
}
