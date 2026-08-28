import Foundation
import ScreenCaptureKit

/// Serviço responsável exclusivamente pela busca de telas e janelas compartilháveis (SRP).
public final class ShareableContentFetcher {
    /// Bundle identifiers de processos de UI do sistema (Central de Controle, Dock, etc.)
    /// que o ScreenCaptureKit reporta como "janelas" mas não são apps compartilháveis.
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.wallpaper.agent",
        "com.apple.screencaptureui"
    ]

    public init() {}

    public func fetchSources() async throws -> [DisplaySource] {
        // `onScreenWindowsOnly: false` de propósito: com `true`, o ScreenCaptureKit omite
        // janelas que estão em outra Área de Trabalho (Space) ou minimizadas. Manter o editor
        // num desktop e o navegador em outro é o arranjo normal de quem dá aula, e a janela
        // simplesmente não aparecia na lista. Os filtros abaixo dão conta do ruído extra.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        var displays: [DisplaySource] = []
        var windows: [DisplaySource] = []

        for display in content.displays {
            displays.append(DisplaySource(scDisplay: display))
        }

        let processoAtual = ProcessInfo.processInfo.processIdentifier

        for window in content.windows {
            guard window.windowLayer == 0 else { continue }
            guard window.frame.width >= 100, window.frame.height >= 100 else { continue }

            // O transmissor não se transmite. A comparação é pelo id do processo, e não
            // pelo bundle: rodando via `swift run` o bundle identifier é nulo, e a própria
            // janela do AulaCast acabava aparecendo como fonte para transmitir.
            guard window.owningApplication?.processID != processoAtual else { continue }

            guard let bundleID = window.owningApplication?.bundleIdentifier,
                  !Self.excludedBundleIdentifiers.contains(bundleID),
                  let appName = window.owningApplication?.applicationName, !appName.isEmpty,
                  let title = window.title, !title.isEmpty else {
                continue
            }

            windows.append(DisplaySource(scWindow: window))
        }

        // Ordem estável por nome do app: a lista ficou maior e mudar de posição a cada
        // atualização faria o professor perder a janela que estava procurando.
        windows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return displays + windows
    }
}