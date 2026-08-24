import Foundation
import CoreMedia
import AulaCastCore

/// Dublês mínimos para montar um MainViewModel sem tocar em captura de tela nem em rede.
/// Servem para testar a ligação entre as camadas — é justamente numa dessas emendas que
/// o id do aluno se perdia e a mão levantada sumia sem erro nenhum.

final class FakeCaptureService: ScreenCaptureProtocol {
    @Published var availableSources: [DisplaySource] = []
    @Published var selectedSource: DisplaySource?
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    @Published var resolution: VideoResolution = .p1080
    @Published var frameRate: Int = 30

    weak var frameReceiver: FrameReceiverProtocol?
    weak var lifecycleObserver: CaptureLifecycleObserverProtocol?

    func fetchAvailableSources() async {}
    func startCapture() async { isRecording = true }
    func stopCapture() async { isRecording = false }
}

final class FakeEncoder: VideoEncoderProtocol {
    weak var outputReceiver: EncodedFrameReceiverProtocol?
    func encode(sampleBuffer: CMSampleBuffer) {}
}

final class FakeAdvertiser: ServiceAdvertiserProtocol {
    private(set) var isAdvertising = false
    func startAdvertising() { isAdvertising = true }
    func stopAdvertising() { isAdvertising = false }
}

final class FakeServer: NetworkServerProtocol {
    var isRunning: Bool = false
    var port: UInt16 = 8080
    var localIPAddress: String = "192.168.1.10"
    var isChatEnabled: Bool = true
    var professorName: String = "Professor"

    weak var chatObserver: ChatObserverProtocol?
    weak var handRaiseObserver: HandRaiseObserverProtocol?
    weak var clientObserver: ClientObserverProtocol?
    weak var presenceObserver: StudentPresenceObserverProtocol?

    /// Mensagens de controle enviadas aos alunos, para inspeção nos testes.
    private(set) var controlMessages: [(type: String, payload: [String: String]?)] = []

    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func broadcastFrame(_ jpegData: Data) {}
    func broadcastChatMessage(_ message: ChatMessage) {}
    func broadcastControlMessage(type: String, payload: [String: String]?) {
        controlMessages.append((type: type, payload: payload))
    }
}
