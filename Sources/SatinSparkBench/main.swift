import Foundation
import SatinSpark
import simd

@discardableResult
private func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = ContinuousClock.now
    let result = try body()
    let duration = start.duration(to: .now)
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1.0e18
    print("\(label): \(String(format: "%.4f", seconds))s")
    return result
}

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    fputs("usage: satin-spark-bench <file.ply>\n", stderr)
    exit(2)
}

let url = URL(fileURLWithPath: path)
let data = try measure("read") {
    try Data(contentsOf: url, options: [.mappedIfSafe])
}
let splats = try measure("parse+pack") {
    try SplatPLYLoader.parse(data)
}
print("splats: \(splats.numSplats)")

let modelViewMatrix = simd_float4x4(
    SIMD4<Float>(1.0, 0.0, 0.0, 0.0),
    SIMD4<Float>(0.0, 1.0, 0.0, 0.0),
    SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
    SIMD4<Float>(0.0, 0.0, -3.0, 1.0)
)
let ordering = measure("sort viewZ") {
    splats.sortedOrdering(modelViewMatrix: modelViewMatrix, metric: .viewZ)
}
print("ordering: \(ordering.count)")
