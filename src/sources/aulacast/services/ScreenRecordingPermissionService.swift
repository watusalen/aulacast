import CoreGraphics
import AppKit
import ScreenCaptureKit

/// Consulta da permissão de Gravação de Tela, atrás de um protocolo para que a regra de
/// "não deixa transmitir sem permissão" possa ser testada — na máquina real ela depende de
/// um clique nos Ajustes do Sistema, que nenhum teste automatizado consegue dar.
public protocol ScreenRecordingPermissionProtocol {
    func isGranted() -> Bool
    func request()
    /// Tenta de fato uma captura: `CGPreflightScreenCaptureAccess` pode seguir falso no
    /// processo em execução depois de o professor ligar a chave nos Ajustes.
    func probe() async -> Bool
}

extension ScreenRecordingPermissionProtocol {
    public func probe() async -> Bool { isGranted() }
}

/// Regras puras da permissão (testáveis sem ScreenCaptureKit nem Ajustes do Sistema).
public enum PermissaoDeTela {
    public static let mensagemNegada =
        "Autorize o AulaCast em Gravação de Tela e reabra o aplicativo."
    public static let mensagemFalhaAoReabrir =
        "Não foi possível reabrir o AulaCast. Feche e abra o aplicativo manualmente."

    /// `SCStreamError.userDeclined` (-3801): o usuário negou a Gravação de Tela.
    public static func ehNegada(_ erro: Error) -> Bool {
        let e = erro as NSError
        return e.domain == SCStreamErrorDomain && e.code == -3801
    }

    /// Só encerra o app se o novo foi de fato aberto; senão o professor ficaria sem nenhum.
    public static func deveEncerrarAposRelancar(app: AnyObject?, error: Error?) -> Bool {
        app != nil && error == nil
    }

    public static var bundleId: String { Bundle.main.bundleIdentifier ?? "com.aulacast.AulaCast" }
    public static var comandoReset: String { "tccutil reset ScreenCapture \(bundleId)" }
}

public func deveEncerrarAposRelancar(app: AnyObject?, error: Error?) -> Bool {
    PermissaoDeTela.deveEncerrarAposRelancar(app: app, error: error)
}

/// Verificação e concessão da permissão "Gravação de Tela" do macOS (SRP).
public struct ScreenRecordingPermissionService: ScreenRecordingPermissionProtocol {
    public init() {}

    public func isGranted() -> Bool { Self.isGranted() }
    public func request() { Self.request() }

    public func probe() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

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
    public static func relaunch(aoFalhar: @escaping @MainActor () -> Void = {}) {
        let caminho = Bundle.main.bundleURL

        // NSWorkspace em vez de `Process` + /usr/bin/open: funciona dentro do App Sandbox.
        let configuracao = NSWorkspace.OpenConfiguration()
        configuracao.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: caminho, configuration: configuracao) { app, erro in
            let encerrar = PermissaoDeTela.deveEncerrarAposRelancar(app: app, error: erro)
            DispatchQueue.main.async {
                if encerrar { NSApplication.shared.terminate(nil) } else { aoFalhar() }
            }
        }
    }
}
