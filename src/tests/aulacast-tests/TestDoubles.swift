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
    @Published var hiddenBundleIDs: Set<String> = []

    weak var frameReceiver: FrameReceiverProtocol?
    weak var lifecycleObserver: CaptureLifecycleObserverProtocol?

    /// Reproduz a captura que não sobe — o caso real é a permissão negada, em que o
    /// ScreenCaptureKit falha e o `isRecording` permanece falso.
    var falhaAoIniciar = false

    /// Quantas vezes a captura foi pedida, e quanto cada pedido demora — o ScreenCaptureKit
    /// real leva centenas de ms, que é a janela em que um duplo clique criava dois streams.
    private(set) var inicios = 0
    var atrasoAoIniciar: UInt64 = 0

    func fetchAvailableSources() async {}

    func startCapture() async {
        inicios += 1
        if atrasoAoIniciar > 0 {
            try? await Task.sleep(nanoseconds: atrasoAoIniciar)
        }
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
    var isStudentChatVisibleToClass: Bool = false

    weak var chatObserver: ChatObserverProtocol?
    weak var clientObserver: ClientObserverProtocol?
    weak var presenceObserver: StudentPresenceObserverProtocol?
    weak var handRaiseObserver: HandRaiseObserverProtocol?
    var onFailure: ((String) -> Void)?

    /// Quadros entregues aos alunos, para conferir que a pausa de fato os segura.
    private(set) var quadrosEnviados = 0

    /// Reproduz a queda assíncrona do servidor real (porta ocupada, por exemplo).
    func simularFalha(_ mensagem: String) {
        isRunning = false
        onFailure?(mensagem)
    }

    /// Mensagens de controle enviadas aos alunos, para inspeção nos testes.
    private(set) var controlMessages: [(type: String, payload: [String: String]?)] = []

    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func broadcastFrame(_ jpegData: Data) { quadrosEnviados += 1 }

    /// Última lista de arquivos entregue ao servidor.
    private(set) var arquivosCompartilhados: [SharedFile] = []
    func updateSharedFiles(_ files: [SharedFile]) { arquivosCompartilhados = files }
    var onFileDownloadUpdate: ((FileDownloadStats) -> Void)?
    func broadcastChatMessage(_ message: ChatMessage) {}

    /// Alunos cuja mão o professor abaixou, na ordem, para conferir o HAND_LOWERED.
    private(set) var maosAbaixadas: [String] = []
    func lowerHand(clientId: String) { maosAbaixadas.append(clientId) }

    /// Cada fixação (texto) e desafixação (`nil`) pedida ao servidor, na ordem.
    private(set) var fixacoes: [String?] = []
    func updatePinnedMessage(_ text: String?) { fixacoes.append(text) }
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
