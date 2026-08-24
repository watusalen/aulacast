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

        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isStreaming ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                if viewModel.clientManager.handRaisedCount > 0 {
                    Text("[\(viewModel.clientManager.handRaisedCount)]")
                        .bold()
                }
            }
        }
    }
}