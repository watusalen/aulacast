import Foundation
import Combine

/// Abstração para serviços de captura de tela/janela (DIP).
public protocol ScreenCaptureProtocol: AnyObject, ObservableObject {
    var availableSources: [DisplaySource] { get }
    var selectedSource: DisplaySource? { get set }
    var isRecording: Bool { get }
    var errorMessage: String? { get }
    var resolution: VideoResolution { get set }
    var frameRate: Int { get set }

    /// Apps marcados para nunca aparecer quando o monitor inteiro é a fonte — ver
    /// `ScreenCaptureService.filtroDeMonitor`.
    var hiddenBundleIDs: Set<String> { get set }

    /// Os apps ocultos lembrados (com nome), em ordem estável, para a lista "Apps ocultos".
    var appsOcultos: [HiddenApp] { get }
    func ocultarApp(bundleID: String, nome: String)
    func mostrarApp(bundleID: String)
    func esquecerTodosOsAppsOcultos()

    var frameReceiver: FrameReceiverProtocol? { get set }
    var lifecycleObserver: CaptureLifecycleObserverProtocol? { get set }
    
    func fetchAvailableSources() async
    func startCapture() async
    func stopCapture() async
}

/// Implementação mínima sobre `hiddenBundleIDs`, para quem não guarda nomes (dublês de teste).
public extension ScreenCaptureProtocol {
    var appsOcultos: [HiddenApp] {
        HiddenAppsStore.ordenados(hiddenBundleIDs.map { HiddenApp(bundleID: $0, nome: $0) })
    }
    func ocultarApp(bundleID: String, nome: String) { hiddenBundleIDs.insert(bundleID) }
    func mostrarApp(bundleID: String) { hiddenBundleIDs.remove(bundleID) }
    func esquecerTodosOsAppsOcultos() { hiddenBundleIDs = [] }
}