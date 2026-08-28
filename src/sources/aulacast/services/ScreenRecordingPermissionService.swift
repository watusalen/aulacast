import CoreGraphics
import AppKit

/// Consulta da permissão de Gravação de Tela, atrás de um protocolo para que a regra de
/// "não deixa transmitir sem permissão" possa ser testada — na máquina real ela depende de
/// um clique nos Ajustes do Sistema, que nenhum teste automatizado consegue dar.
public protocol ScreenRecordingPermissionProtocol {
    func isGranted() -> Bool
    func request()
}

/// Verificação e concessão da permissão "Gravação de Tela" do macOS (SRP).
public struct ScreenRecordingPermissionService: ScreenRecordingPermissionProtocol {
    public init() {}

    public func isGranted() -> Bool { Self.isGranted() }
    public func request() { Self.request() }

    public static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Registra o aplicativo no banco de permissões do macOS e dispara o aviso nativo.
    ///
    /// Sem esta chamada o AulaCast **não aparece** na lista de Gravação de Tela dos Ajustes:
    /// o sistema só lista aplicativos que já pediram a permissão alguma vez. Mandar o
    /// professor para os Ajustes antes de pedir o levava a uma lista sem o AulaCast nela.
    public static func request() {
        CGRequestScreenCaptureAccess()
    }

    public static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Fecha e reabre o aplicativo.
    ///
    /// O macOS não aplica a permissão de Gravação de Tela a um processo que já estava rodando
    /// quando ela foi concedida — é por isso que o próprio sistema oferece "Encerrar e
    /// Reabrir". Quem clica em "Mais Tarde" fica com um AulaCast que tem a permissão nos
    /// Ajustes e mesmo assim não captura nada, sem nenhuma pista do porquê.
    public static func relaunch() {
        let caminho = Bundle.main.bundleURL

        let processo = Process()
        processo.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        processo.arguments = ["-n", caminho.path]
        try? processo.run()

        NSApplication.shared.terminate(nil)
    }
}
