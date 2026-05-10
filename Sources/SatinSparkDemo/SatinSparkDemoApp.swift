import SatinSpark
import SwiftUI

@main
struct SatinSparkDemoApp: App {
    var body: some Scene {
        WindowGroup("Satin Spark") {
            SplatDemoView()
                .frame(minWidth: 640, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}
