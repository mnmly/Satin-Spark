#if canImport(SwiftUI)
import Satin
import SwiftUI

public struct SplatDemoView: View {
    private let renderer: SplatDemoRenderer

    public init(renderer: SplatDemoRenderer = SplatDemoRenderer()) {
        self.renderer = renderer
    }

    public var body: some View {
        SatinMetalView(renderer: renderer)
    }
}
#endif

