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
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Mostrar pasta de dados no Finder") { PastasDoApp.mostrarNoFinder() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}