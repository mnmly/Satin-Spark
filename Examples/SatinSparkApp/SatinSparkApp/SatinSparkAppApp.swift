//
//  SatinSparkAppApp.swift
//  SatinSparkApp
//
//  Created by HIROAKI YAMANE on 10/05/2026.
//

import SwiftUI

@main
struct SatinSparkAppApp: App {
    private let initialURL = CommandLine.arguments.dropFirst()
        .first(where: { $0.hasSuffix(".ply") })
        .map(URL.init(fileURLWithPath:))

    var body: some Scene {
        WindowGroup {
            ContentView(initialURL: initialURL)
        }
    }
}
