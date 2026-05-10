import Foundation
import CoreGraphics
import ImageIO
import SatinSpark
import Testing
import UniformTypeIdentifiers
import simd

@Suite
struct SplatReferenceTests {
    @Test
    func deterministicFixtureDecodesPackedSplats() {
        let splats = SplatFixtures.deterministicScene()

        #expect(splats.numSplats == 5)

        let decoded0 = SplatReference.decodePackedSplat(
            splats.packedWords(at: 0),
            encoding: splats.splatEncoding
        )
        expectApproximatelyEqual(decoded0.center, [-0.72021484, -0.23999023, 0.0], tolerance: 0.00001)
        expectApproximatelyEqual(decoded0.scales, [0.07012469, 0.033320747, 0.033320747], tolerance: 0.00001)
        expectApproximatelyEqual(decoded0.rgba, [1.0, 0.18039216, 0.12156863, 0.72156864], tolerance: 0.00001)

        let decoded4 = SplatReference.decodePackedSplat(
            splats.packedWords(at: 4),
            encoding: splats.splatEncoding
        )
        expectApproximatelyEqual(decoded4.center, [0.0, 0.0, 0.2800293], tolerance: 0.00001)
        expectApproximatelyEqual(decoded4.scales, [0.08986483, 0.08986483, 0.08986483], tolerance: 0.00001)
        expectApproximatelyEqual(decoded4.rgba, [0.8784314, 0.52156866, 1.0, 0.34117648], tolerance: 0.00001)
    }

    @Test
    func deterministicFixtureProjectsToExpectedRadii() throws {
        let splats = SplatFixtures.deterministicScene()
        let modelViewMatrix = translationMatrix([0.0, 0.0, -3.2])
        let projectionMatrix = perspectiveProjectionMatrix(fovYDegrees: 45.0, aspect: 1.0, near: 0.01, far: 100.0)
        let renderSize = SIMD2<Float>(512.0, 512.0)

        let expectedRadii: [(Float, Float)] = [
            (55.502224, 26.320381),
            (47.159126, 31.295895),
            (40.446587, 32.600067),
            (51.139397, 25.028118),
            (53.82101, 53.82101),
        ]

        for index in 0 ..< splats.numSplats {
            let decoded = SplatReference.decodePackedSplat(
                splats.packedWords(at: index),
                encoding: splats.splatEncoding
            )
            let projected = try #require(SplatReference.project(
                decoded,
                modelViewMatrix: modelViewMatrix,
                projectionMatrix: projectionMatrix,
                renderSize: renderSize
            ))

            expectApproximatelyEqual(projected.radius1, expectedRadii[index].0, tolerance: 0.0005)
            expectApproximatelyEqual(projected.radius2, expectedRadii[index].1, tolerance: 0.0005)
            #expect(projected.viewCenter.z < 0.0)
            #expect(projected.rgba.w >= 1.0 / 255.0)
        }
    }

    @Test
    func packedSplatsExposeSparkStyleCpuHelpers() throws {
        let original = PackedSplat(
            center: [0.125, -0.25, 0.375],
            scale: [0.05, 0.08, 0.03],
            rotation: simd_quatf(angle: 0.4, axis: normalize(SIMD3<Float>(0.2, 0.7, 0.1))),
            opacity: 0.5,
            color: [0.2, 0.4, 0.8]
        )
        let splats = PackedSplats(splats: [original])
        let initial = splats.packedWords(at: 0)

        let unpacked = splats.getSplat(at: 0)
        expectApproximatelyEqual(unpacked.center, [0.125, -0.25, 0.375], tolerance: 0.00001)
        expectApproximatelyEqual(unpacked.color, [0.2, 0.4, 0.8], tolerance: 0.002)
        expectApproximatelyEqual(unpacked.opacity, 0.5, tolerance: 0.002)

        splats.setCenter([-0.5, 0.625, -0.75], at: 0)
        var words = splats.packedWords(at: 0)
        #expect(words.x == initial.x)
        #expect((words.z & 0xffff0000) == (initial.z & 0xffff0000))
        #expect(words.w == initial.w)
        expectApproximatelyEqual(splats.getSplat(at: 0).center, [-0.5, 0.625, -0.75], tolerance: 0.00001)

        splats.setScale([0.12, 0.06, 0.001], at: 0)
        words = splats.packedWords(at: 0)
        #expect((words.w & 0xff000000) == (initial.w & 0xff000000))
        expectApproximatelyEqual(splats.getSplat(at: 0).scale, [0.11516171, 0.0594372, 0.0010343151], tolerance: 0.00001)

        splats.setRotation(simd_quatf(angle: -0.2, axis: [0.0, 0.0, 1.0]), at: 0)
        words = splats.packedWords(at: 0)
        #expect((words.z & 0x0000ffff) == UInt32(Float16(-0.75).bitPattern))
        #expect((words.w & 0x00ffffff) != 0)
        expectApproximatelyEqual(abs(simd_dot(splats.getSplat(at: 0).rotation.vector, simd_quatf(angle: 0.2, axis: [0.0, 0.0, -1.0]).vector)), 1.0, tolerance: 0.02)

        splats.setColor([1.0, 0.0, 0.5], at: 0)
        words = splats.packedWords(at: 0)
        #expect((words.x & 0xff000000) == (initial.x & 0xff000000))
        expectApproximatelyEqual(splats.getSplat(at: 0).color, [1.0, 0.0, 0.5019608], tolerance: 0.00001)

        splats.setOpacity(0.25, at: 0)
        expectApproximatelyEqual(splats.getSplat(at: 0).opacity, 0.2509804, tolerance: 0.00001)

        var visited: [Int] = []
        splats.forEachSplat { index, splat in
            visited.append(index)
            expectApproximatelyEqual(splat.opacity, 0.2509804, tolerance: 0.00001)
        }
        #expect(visited == [0])
    }

    @Test
    func packedHelpersHonorCustomEncodingAndLodOpacity() {
        let encoding = SplatEncoding(
            rgbMin: -1.0,
            rgbMax: 3.0,
            lnScaleMin: -8.0,
            lnScaleMax: 4.0,
            lodOpacity: true
        )
        let splats = PackedSplats(maxSplats: 1, splatEncoding: encoding)
        splats.setSplat(
            PackedSplat(
                center: [0.0, 0.0, 0.0],
                scale: [0.02, 0.04, 0.08],
                opacity: 0.8,
                color: [0.0, 1.0, 2.0]
            ),
            at: 0
        )

        let unpacked = splats.getSplat(at: 0)
        expectApproximatelyEqual(unpacked.color, [0.003921628, 1.0078433, 1.9960785], tolerance: 0.00001)
        expectApproximatelyEqual(unpacked.opacity, 0.8, tolerance: 0.004)

        splats.setRGBA(color: [3.0, -1.0, 1.0], opacity: 0.5, at: 0)
        let rgba = splats.getSplat(at: 0)
        expectApproximatelyEqual(rgba.color, [3.0, -1.0, 1.0078433], tolerance: 0.00001)
        expectApproximatelyEqual(rgba.opacity, 0.5019608, tolerance: 0.00001)
    }

    @Test
    func packedHelpersSanitizeNonFiniteValues() {
        let splats = PackedSplats(splats: [
            PackedSplat(
                center: [.infinity, -.infinity, .nan],
                scale: [.infinity, .nan, -1.0],
                opacity: .nan,
                color: [.infinity, -.infinity, .nan]
            ),
        ])

        let unpacked = splats.getSplat(at: 0)
        expectApproximatelyEqual(unpacked.center, [0.0, 0.0, 0.0], tolerance: 0.0)
        expectApproximatelyEqual(unpacked.color, [1.0, 0.0, 0.0], tolerance: 0.00001)
        expectApproximatelyEqual(unpacked.opacity, 0.0, tolerance: 0.00001)
        expectApproximatelyEqual(unpacked.scale, [0.0, 0.0, 0.0], tolerance: 0.00001)
    }

    @Test
    func sortedOrderingSupportsViewZAndRadialMetrics() {
        let splats = PackedSplats(splats: [
            PackedSplat(center: [0.0, 0.0, 0.0], scale: [0.05, 0.05, 0.05]),
            PackedSplat(center: [0.0, 0.0, -1.0], scale: [0.05, 0.05, 0.05]),
            PackedSplat(center: [2.0, 0.0, 0.0], scale: [0.05, 0.05, 0.05]),
            PackedSplat(center: [0.0, 0.0, 1.0], scale: [0.05, 0.05, 0.05]),
        ])
        let modelViewMatrix = translationMatrix([0.0, 0.0, -3.0])

        #expect(splats.sortedOrdering(modelViewMatrix: modelViewMatrix, metric: .viewZ) == [1, 0, 2, 3])
        #expect(splats.sortedOrdering(modelViewMatrix: modelViewMatrix, metric: .radial) == [1, 2, 0, 3])
    }

    @Test
    func plyLoaderParsesAsciiGaussianSplatProperties() throws {
        let ply = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float opacity
        property float scale_0
        property float scale_1
        property float scale_2
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        1.0 -2.0 3.0 0.0 0.0 0.0 0.0 -3.0 -2.5 -2.0 1.0 0.0 0.0 0.0
        """

        let splats = try SplatPLYLoader.parse(Data(ply.utf8))
        #expect(splats.numSplats == 1)

        let splat = splats.getSplat(at: 0)
        expectApproximatelyEqual(splat.center, [1.0, -2.0, 3.0], tolerance: 0.00001)
        expectApproximatelyEqual(splat.color, [0.5019608, 0.5019608, 0.5019608], tolerance: 0.00001)
        expectApproximatelyEqual(splat.opacity, 0.5019608, tolerance: 0.00001)
        expectApproximatelyEqual(splat.scale.x, exp(-3.0), tolerance: 0.004)
        expectApproximatelyEqual(splat.scale.y, exp(-2.5), tolerance: 0.004)
        expectApproximatelyEqual(splat.scale.z, exp(-2.0), tolerance: 0.004)
    }

    @Test
    func plyLoaderParsesBinaryLittleEndianGaussianSplatProperties() throws {
        let header = [
            "ply",
            "format binary_little_endian 1.0",
            "element vertex 1",
            "property float x",
            "property float y",
            "property float z",
            "property float f_dc_0",
            "property float f_dc_1",
            "property float f_dc_2",
            "property float opacity",
            "property float scale_0",
            "property float scale_1",
            "property float scale_2",
            "property float rot_0",
            "property float rot_1",
            "property float rot_2",
            "property float rot_3",
            "end_header\n",
        ].joined(separator: "\n")
        var data = Data(header.utf8)
        for value in [1.0, -2.0, 3.0, 0.0, 0.0, 0.0, 0.0, -3.0, -2.5, -2.0, 1.0, 0.0, 0.0, 0.0] as [Float] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        let splats = try SplatPLYLoader.parse(data)
        #expect(splats.numSplats == 1)

        let splat = splats.getSplat(at: 0)
        expectApproximatelyEqual(splat.center, [1.0, -2.0, 3.0], tolerance: 0.00001)
        expectApproximatelyEqual(splat.color, [0.5019608, 0.5019608, 0.5019608], tolerance: 0.00001)
        expectApproximatelyEqual(splat.opacity, 0.5019608, tolerance: 0.00001)
        expectApproximatelyEqual(splat.scale.x, exp(-3.0), tolerance: 0.004)
        expectApproximatelyEqual(splat.scale.y, exp(-2.5), tolerance: 0.004)
        expectApproximatelyEqual(splat.scale.z, exp(-2.0), tolerance: 0.004)
    }

    @Test
    func plyLoaderPacksSphericalHarmonics() throws {
        var header = [
            "ply",
            "format ascii 1.0",
            "element vertex 1",
            "property float x",
            "property float y",
            "property float z",
            "property float f_dc_0",
            "property float f_dc_1",
            "property float f_dc_2",
            "property float opacity",
            "property float scale_0",
            "property float scale_1",
            "property float scale_2",
            "property float rot_0",
            "property float rot_1",
            "property float rot_2",
            "property float rot_3",
        ]
        for index in 0 ..< 9 {
            header.append("property float f_rest_\(index)")
        }
        header.append("end_header")

        let shValues: [Float] = [
            0.25, -0.25, 0.5,
            -0.5, 0.75, -0.75,
            1.0, -1.0, 0.125,
        ]
        let baseValues: [Float] = [0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, -3.0, -3.0, -3.0, 1.0, 0.0, 0.0, 0.0]
        var values = baseValues
        values.append(contentsOf: shValues)
        let row = values
            .map { String($0) }
            .joined(separator: " ")
        let ply = header.joined(separator: "\n") + "\n" + row + "\n"

        let splats = try SplatPLYLoader.parse(Data(ply.utf8))
        #expect(splats.sphericalHarmonics.degree == 1)
        #expect(splats.sphericalHarmonics.sh1?.count == 2)
        #expect(splats.sphericalHarmonics.sh2 == nil)
        #expect(splats.sphericalHarmonics.sh3 == nil)
        #expect(splats.sphericalHarmonics.sh1 != [0, 0])
    }

    @Test
    func loaderDetectsSparkFileTypes() {
        #expect(SplatLoader.fileType(for: Data("ply\n".utf8)) == .ply)
        #expect(SplatLoader.fileType(for: Data([0x1f, 0x8b, 0x08, 0x00])) == .spz)
        #expect(SplatLoader.fileType(for: Data([0x4e, 0x47, 0x53, 0x50])) == .spz)
        #expect(SplatLoader.fileType(for: Data([0x50, 0x4b, 0x03, 0x04])) == .pcsogszip)
        #expect(SplatLoader.fileType(for: Data([0x52, 0x41, 0x44, 0x30])) == .rad)
        #expect(SplatLoader.fileType(for: Data(), path: "/tmp/model.splat") == .splat)
        #expect(SplatLoader.fileType(for: Data(), path: "/tmp/model.ksplat") == .ksplat)
        #expect(SplatLoader.fileType(for: Data(), path: "/tmp/model.sog") == .pcsogszip)
        #expect(SplatLoader.fileType(for: Data(), path: "/tmp/meta.json") == .pcsogs)
    }

    @Test
    func loaderRoutesPlyThroughPublicDispatcher() throws {
        let ply = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property uchar alpha
        end_header
        0.25 -0.5 1.0 64 128 255 192
        """

        let splats = try SplatLoader.parse(Data(ply.utf8), path: "/tmp/fixture.ply")
        let splat = splats.getSplat(at: 0)
        expectApproximatelyEqual(splat.center, [0.25, -0.5, 1.0], tolerance: 0.00001)
        expectApproximatelyEqual(splat.color, [Float(64.0 / 255.0), Float(128.0 / 255.0), 1.0], tolerance: 0.002)
        expectApproximatelyEqual(splat.opacity, 192.0 / 255.0, tolerance: 0.002)
    }

    @Test
    func pcsogsLoaderPacksSphericalHarmonics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("satin-spark-pcsogs-sh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try writePNG([0, 0, 0, 255], width: 1, height: 1, to: directory.appendingPathComponent("means_l.png"))
        try writePNG([0, 0, 0, 255], width: 1, height: 1, to: directory.appendingPathComponent("means_h.png"))
        try writePNG([0, 0, 0, 255], width: 1, height: 1, to: directory.appendingPathComponent("scales.png"))
        try writePNG([128, 128, 128, 252], width: 1, height: 1, to: directory.appendingPathComponent("quats.png"))
        try writePNG([128, 128, 128, 255], width: 1, height: 1, to: directory.appendingPathComponent("sh0.png"))
        try writePNG([0, 0, 0, 255], width: 1, height: 1, to: directory.appendingPathComponent("labels.png"))

        var centroids = Array(repeating: UInt8(128), count: 15 * 4)
        for index in 0 ..< 15 {
            centroids[index * 4 + 3] = 255
        }
        centroids[0] = 192
        centroids[5] = 64
        centroids[10] = 255
        try writePNG(centroids, width: 15, height: 1, to: directory.appendingPathComponent("shn_centroids.png"))

        let zeroCodebook = Array(repeating: 0.0, count: 256)
        let shCodebook = (0 ..< 256).map { (Double($0) - 128.0) / 128.0 }
        let metadata: [String: Any] = [
            "version": 2,
            "count": 1,
            "means": [
                "mins": [0.0, 0.0, 0.0],
                "maxs": [0.0, 0.0, 0.0],
                "files": ["means_l.png", "means_h.png"],
            ],
            "scales": [
                "codebook": zeroCodebook,
                "files": ["scales.png"],
            ],
            "quats": [
                "files": ["quats.png"],
            ],
            "sh0": [
                "codebook": zeroCodebook,
                "files": ["sh0.png"],
            ],
            "shN": [
                "bands": 1,
                "codebook": shCodebook,
                "files": ["shn_centroids.png", "labels.png"],
            ],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])

        let splats = try SplatPCSOGSLoader.parse(metadataData, baseURL: directory)
        #expect(splats.numSplats == 1)
        #expect(splats.sphericalHarmonics.degree == 1)
        #expect(splats.sphericalHarmonics.sh1?.count == 2)
        #expect(splats.sphericalHarmonics.sh1 != [0, 0])
    }

    @Test
    func rawSplatLoaderParsesSparkAntisplatRecords() throws {
        var data = Data()
        appendFloat32(1.0, to: &data)
        appendFloat32(-2.0, to: &data)
        appendFloat32(3.0, to: &data)
        appendFloat32(0.05, to: &data)
        appendFloat32(0.08, to: &data)
        appendFloat32(0.11, to: &data)
        data.append(contentsOf: [26, 128, 230, 204])
        data.append(contentsOf: [255, 128, 128, 128])

        let splats = try SplatLoader.parse(data, path: "/tmp/fixture.splat")
        #expect(splats.numSplats == 1)

        let splat = splats.getSplat(at: 0)
        expectApproximatelyEqual(splat.center, [1.0, -2.0, 3.0], tolerance: 0.00001)
        expectApproximatelyEqual(
            splat.color,
            [Float(26.0 / 255.0), Float(128.0 / 255.0), Float(230.0 / 255.0)],
            tolerance: 0.002
        )
        expectApproximatelyEqual(splat.opacity, 204.0 / 255.0, tolerance: 0.002)
        expectApproximatelyEqual(splat.scale, [0.05, 0.08, 0.11], tolerance: 0.004)
    }

    @Test
    func rawSplatLoaderRejectsTruncatedRecords() {
        do {
            _ = try SplatRawSplatLoader.parse(Data(repeating: 0, count: 31))
            #expect(Bool(false), "Expected invalid .splat byte count to throw")
        } catch SplatRawSplatLoaderError.invalidByteCount(31) {
            #expect(Bool(true))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test
    func spzLoaderParsesVersion3FixedPointRecords() throws {
        let splats = try SplatLoader.parse(makeSPZFixtureData(), path: "/tmp/fixture.spz")
        #expect(splats.numSplats == 1)

        let splat = splats.getSplat(at: 0)
        expectApproximatelyEqual(splat.center, [1.0, -2.0, 3.0], tolerance: 0.00001)
        expectApproximatelyEqual(
            splat.color,
            [spzColor(128), spzColor(64), spzColor(255)],
            tolerance: 0.003
        )
        expectApproximatelyEqual(splat.opacity, 204.0 / 255.0, tolerance: 0.002)
        expectApproximatelyEqual(
            splat.scale,
            [exp(Float(112) / 16.0 - 10.0), exp(Float(120) / 16.0 - 10.0), exp(Float(128) / 16.0 - 10.0)],
            tolerance: 0.006
        )
        #expect(splats.sphericalHarmonics.degree == 1)
        #expect(splats.sphericalHarmonics.sh1?.count == 2)
        #expect(splats.sphericalHarmonics.sh1 != [0, 0])
    }

    @Test
    func spzLoaderInflatesGzipWrappedFiles() throws {
        let gzipFixture = Data([
            31, 139, 8, 0, 0, 0, 0, 0, 2, 19, 243, 115, 15, 14, 96, 102,
            96, 96, 96, 4, 98, 6, 30, 32, 22, 96, 96, 120, 240, 159, 193, 128,
            225, 76, 131, 195, 255, 130, 138, 6, 160, 200, 1, 0, 151, 81, 98,
            224, 36, 0, 0, 0,
        ])

        let splats = try SplatLoader.parse(gzipFixture, path: "/tmp/fixture.spz")
        #expect(splats.numSplats == 1)
        expectApproximatelyEqual(splats.getSplat(at: 0).center, [1.0, -2.0, 3.0], tolerance: 0.00001)
    }

}

private func expectApproximatelyEqual(_ actual: Float, _ expected: Float, tolerance: Float) {
    #expect(abs(actual - expected) <= tolerance)
}

private func expectApproximatelyEqual(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, tolerance: Float) {
    expectApproximatelyEqual(actual.x, expected.x, tolerance: tolerance)
    expectApproximatelyEqual(actual.y, expected.y, tolerance: tolerance)
    expectApproximatelyEqual(actual.z, expected.z, tolerance: tolerance)
}

private func expectApproximatelyEqual(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>, tolerance: Float) {
    expectApproximatelyEqual(actual.x, expected.x, tolerance: tolerance)
    expectApproximatelyEqual(actual.y, expected.y, tolerance: tolerance)
    expectApproximatelyEqual(actual.z, expected.z, tolerance: tolerance)
    expectApproximatelyEqual(actual.w, expected.w, tolerance: tolerance)
}

private func appendFloat32(_ value: Float, to data: inout Data) {
    var bitPattern = value.bitPattern.littleEndian
    withUnsafeBytes(of: &bitPattern) { data.append(contentsOf: $0) }
}

private func makeSPZFixtureData() -> Data {
    var data = Data()
    appendUInt32(0x5053474e, to: &data)
    appendUInt32(3, to: &data)
    appendUInt32(1, to: &data)
    data.append(contentsOf: [1, 12, 0, 0])
    appendInt24(4096, to: &data)
    appendInt24(-8192, to: &data)
    appendInt24(12288, to: &data)
    data.append(204)
    data.append(contentsOf: [128, 64, 255])
    data.append(contentsOf: [112, 120, 128])
    data.append(contentsOf: [0, 0, 0, 0xc0])
    data.append(contentsOf: [160, 96, 192, 64, 224, 32, 255, 0, 144])
    return data
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func appendInt24(_ value: Int32, to data: inout Data) {
    let unsigned = UInt32(bitPattern: value) & 0x00ff_ffff
    data.append(UInt8(unsigned & 0xff))
    data.append(UInt8((unsigned >> 8) & 0xff))
    data.append(UInt8((unsigned >> 16) & 0xff))
}

private func spzColor(_ byte: UInt8) -> Float {
    let scale = Float(0.28209479177387814 / 0.15)
    return min(max((Float(byte) / 255.0 - 0.5) * scale + 0.5, 0.0), 1.0)
}

private func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
    precondition(pixels.count == width * height * 4)
    var pixels = pixels
    let data = NSMutableData()
    try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    try (data as Data).write(to: url)
}

private func translationMatrix(_ translation: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1.0, 0.0, 0.0, 0.0),
        SIMD4<Float>(0.0, 1.0, 0.0, 0.0),
        SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
        SIMD4<Float>(translation.x, translation.y, translation.z, 1.0)
    )
}

private func perspectiveProjectionMatrix(fovYDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1.0 / tan((fovYDegrees * .pi / 180.0) * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    let wz = (near * far) / (near - far)
    return simd_float4x4(
        SIMD4<Float>(x, 0.0, 0.0, 0.0),
        SIMD4<Float>(0.0, y, 0.0, 0.0),
        SIMD4<Float>(0.0, 0.0, z, -1.0),
        SIMD4<Float>(0.0, 0.0, wz, 0.0)
    )
}
