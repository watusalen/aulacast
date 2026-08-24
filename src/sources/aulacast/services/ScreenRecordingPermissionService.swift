import CoreGraphics
import AppKit

/// Verificação e concessão da permissão "Gravação de Tela" do macOS (SRP).
public enum ScreenRecordingPermissionService {
    public static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Dispara o prompt nativo do sistema na primeira vez que é chamado.
    public static func request() {
        CGRequestScreenCaptureAccess()
    }

    public static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
