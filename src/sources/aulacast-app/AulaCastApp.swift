import SwiftUI
import AulaCastCore

@main
public struct AulaCastApp: App {
    @NSApplicationDelegateAdaptor(DelegadoDoApp.self) private var delegado
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
            // "Sobre" e a pasta de dados ficam no menu do app; Arquivo, Editar, Visualizar e
            // Ajuda saem da barra (veja `BarraDeMenus`), e só "Janela" permanece.
            CommandGroup(replacing: .appInfo) {
                Button("Sobre o AulaCast") { Task { @MainActor in SobreJanela.mostrar() } }
                Divider()
                Button("Mostrar pasta de dados no Finder") { PastasDoApp.mostrarNoFinder() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            // Sem o menu Arquivo não há "Fechar": ele passa para o menu Janela.
            CommandGroup(after: .windowSize) {
                Button("Fechar") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
        }
    }
}
