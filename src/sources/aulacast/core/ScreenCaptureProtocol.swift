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

    var frameReceiver: FrameReceiverProtocol? { get set }
    var lifecycleObserver: CaptureLifecycleObserverProtocol? { get set }
    
    func fetchAvailableSources() async
    func startCapture() async
    func stopCapture() async
}