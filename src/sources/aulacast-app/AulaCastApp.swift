import SwiftUI
import AulaCastCore

@main
public struct AulaCastApp: App {
    @StateObject private var viewModel = MainViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainDashboardView()
                .environmentObject(viewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)
    }
}