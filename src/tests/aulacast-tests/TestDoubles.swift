import Foundation
import CoreMedia
import AulaCastCore

/// Dublês mínimos para montar um MainViewModel sem tocar em captura de tela nem em rede.
/// Servem para testar a ligação entre as camadas — é justamente numa dessas emendas que
/// o id do aluno se perdia e a mão levantada sumia sem erro nenhum.

/// Simula a permissão de Gravação de Tela, que numa máquina real depende de um clique
/// do usuário nos Ajustes do Sistema e não pode ser exercitada por teste automatizado.
final class FakePermission: ScreenRecordingPermissionProtocol {
    var concedida: Bool
    private(set) var pedidosFeitos = 0

    init(concedida: Bool) { self.concedida = concedida }

    func isGranted() -> Bool { concedida }
    func request() { pedidosFeitos += 1 }
}

final class FakeCaptureService: ScreenCaptureProtocol {
    @Published var availableSources: [DisplaySource] = []
    @Published var selectedSource: DisplaySource?
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    @Published var resolution: VideoResolution = .p1080
    @Published var frameRate: Int = 30

    weak var frameReceiver: FrameReceiverProtocol?
    weak var lifecycleObserver: CaptureLifecycleObserverProtocol?

    /// Reproduz a captura que não sobe — o caso real é a permissão negada, em que o
    /// ScreenCaptureKit falha e o `isRecording` permanece falso.
    var falhaAoIniciar = false

    func fetchAvailableSources() async {}

    func startCapture() async {
        if falhaAoIniciar {
            errorMessage = "Falha ao iniciar captura: permissão negada."
            return
        }
        isRecording = true
    }

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

/// Registra as chamadas de proteção contra o App Nap, para os testes verificarem
/// que ela é ligada ao transmitir e liberada em todos os caminhos de encerramento.
final class FakeSystemActivity: SystemActivityProtocol {
    private(set) var inicios = 0
    private(set) var fins = 0
    private(set) var ultimaRazao: String?

    var isHoldingActivity: Bool { inicios > fins }

    /// Pedir de novo com a proteção já segurada não faz nada, e soltar sem ter nada
    /// segurado também não — é o contrato do SystemActivityService real, que guarda um
    /// único token. Sem espelhar isso aqui, o dublê contaria chamadas que o sistema
    /// operacional ignora e os testes passariam a medir a coisa errada.
    func beginTransmission(reason: String) {
        ultimaRazao = reason
        guard !isHoldingActivity else { return }
        inicios += 1
    }

    func endTransmission() {
        guard isHoldingActivity else { return }
        fins += 1
    }
}
