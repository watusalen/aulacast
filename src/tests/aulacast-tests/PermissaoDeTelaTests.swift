import Foundation
import AulaCastCore

/// Testes CORE da checagem de permissão de Gravação de Tela (probe, reverificação, relançar, -3801).
@MainActor
func testesPermissaoDeTela(
    _ assertTest: (Bool, String) -> Void,
    _ montarVM: (Bool, Bool) -> (MainViewModel, FakeCaptureService, FakeServer)
) async {
    print("\n--- [39] Permissão de tela: probe, reverificação e relançar ---")
    func vm(granted: Bool, probe: Bool) -> (MainViewModel, FakeCaptureService) {
        let (v, c, _) = montarVM(granted, false)
        (v.permission as? FakePermission)?.probeOk = probe
        return (v, c)
    }
    func permissao(_ v: MainViewModel) -> FakePermission? { v.permission as? FakePermission }

    do {
        let (v, c) = vm(granted: false, probe: true)
        v.startStream()
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTest(!v.needsScreenRecordingPermission && c.isRecording, "Probe verdadeiro libera a transmissão mesmo com isGranted falso")
        v.stopStream()
    }
    do {
        let (v, c) = vm(granted: false, probe: false)
        v.startStream()
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTest(v.needsScreenRecordingPermission && !c.isRecording && v.streamErrorMessage != nil,
                   "Sem preflight e sem probe: bloqueia e mostra o banner")
        let ok = await v.reverificarPermissao()
        assertTest(!ok && v.needsScreenRecordingPermission && v.streamErrorMessage != nil, "Reverificar com probe falso mantém o banner")
        permissao(v)?.probeOk = true
        let ok2 = await v.reverificarPermissao()
        assertTest(ok2 && !v.needsScreenRecordingPermission && v.streamErrorMessage == nil, "Reverificar com probe verdadeiro limpa banner e erro")
    }
    do {
        let dominio = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
        assertTest(PermissaoDeTela.ehNegada(NSError(domain: dominio, code: -3801)), "-3801 do ScreenCaptureKit vira 'permissão negada'")
        assertTest(!PermissaoDeTela.ehNegada(NSError(domain: dominio, code: -3802))
                   && !PermissaoDeTela.ehNegada(NSError(domain: "x", code: -3801)), "Outros erros seguem genéricos")
    }
    do {
        let app = NSObject()
        assertTest(deveEncerrarAposRelancar(app: app, error: nil), "Relançar com sucesso encerra o app")
        assertTest(!deveEncerrarAposRelancar(app: nil, error: nil), "Relançar sem app novo mantém o app aberto")
        assertTest(!deveEncerrarAposRelancar(app: app, error: NSError(domain: "x", code: 1)), "Relançar com erro mantém o app aberto")
    }
}
