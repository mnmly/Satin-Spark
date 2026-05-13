import Foundation

public enum SplatPerfLog {
    nonisolated(unsafe) public static var enabled: Bool = {
        ProcessInfo.processInfo.environment["SATIN_SPARK_PERF_LOG"].map { $0 != "0" && !$0.isEmpty } ?? false
    }()

    @discardableResult
    @inline(__always)
    public static func measure<T>(_ label: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = ContinuousClock.now
        let result = try body()
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1.0e18
        log(String(format: "%@: %.4fs", label(), seconds))
        return result
    }

    @inline(__always)
    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        fputs("[SatinSpark] \(message())\n", stderr)
    }
}
