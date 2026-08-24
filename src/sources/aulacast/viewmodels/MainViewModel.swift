import Foundation
import SwiftUI
import Combine
import CoreMedia
import AppKit

@MainActor
public final class MainViewModel: ObservableObject {
    @Published public var isStreaming: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var serverURLString: String = "http://127.0.0.1:8080"
    @Published public var streamStartedAt: Date?
    @Published public var latestPreviewImage: NSImage?

    /// Erro que derrubou a transmissão sozinha (monitor desconectado, permissão revogada…).
    @Published public var streamErrorMessage: String?

    /// Compartilhado com a thread de captura (que não pode tocar em estado da MainActor).
    public let streamState = StreamRuntimeState()

    @Published public var isChatEnabled: Bool = true {
        didSet { serverService.isChatEnabled = isChatEnabled }
    }

    /// Vazio por padrão: o app é usado por qualquer professor, então não se assume o nome
    /// da conta do Mac. Quem quiser aparecer identificado preenche nas configurações.
    @Published public var professorName: String = "" {
        didSet { serverService.professorName = professorName }
    }

    public let captureService: any ScreenCaptureProtocol
    public let advertiserService: ServiceAdvertiserProtocol

    // Acessados a cada quadro pela thread de captura; ambos são imutáveis e protegidos
    // internamente por lock, então não devem exigir salto para a MainActor.
    nonisolated(unsafe) public let encoderService: VideoEncoderProtocol
    nonisolated(unsafe) public let serverService: NetworkServerProtocol

    public let chatManager: ChatManagerService
    public let clientManager: ClientManagerService

    private var cancellables = Set<AnyCancellable>()

    public init(
        captureService: any ScreenCaptureProtocol = ScreenCaptureService(),
        encoderService: VideoEncoderProtocol = MJPEGFrameEncoder(),
        serverService: NetworkServerProtocol = NetworkListenerService(port: 8080, webAssetsPath: WebAssetsPathResolver.resolve()),
        advertiserService: ServiceAdvertiserProtocol = BonjourAdvertiserService(),
        chatManager: ChatManagerService = ChatManagerService(),
        clientManager: ClientManagerService = ClientManagerService()
    ) {
        self.captureService = captureService
        self.encoderService = encoderService
        self.serverService = serverService
        self.advertiserService = advertiserService
        self.chatManager = chatManager
        self.clientManager = clientManager

        // Encadeia objectWillChange dos sub-managers para que a UI reaja a mudancas internas
        chatManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        clientManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Conexao de pipelines via protocolos
        self.captureService.frameReceiver = self
        self.captureService.lifecycleObserver = self
        self.encoderService.outputReceiver = self
        self.serverService.chatObserver = self
        self.serverService.presenceObserver = self
        self.serverService.handRaiseObserver = self
        self.serverService.clientObserver = self
        self.serverService.professorName = self.professorName
        self.serverService.isChatEnabled = self.isChatEnabled

        self.updateServerURL()
    }

    public func sendProfMessage(text: String) {
        chatManager.sendProfMessage(text: text)
        if let lastMsg = chatManager.messages.last, lastMsg.isProf {
            serverService.broadcastChatMessage(lastMsg)
        }
    }

    public func startStream() {
        Task {
            self.streamErrorMessage = nil
            await captureService.startCapture()
            do {
                try serverService.start()
                advertiserService.startAdvertising()
                self.isStreaming = true
                self.isPaused = false
                self.streamState.reset()
                self.streamStartedAt = Date()
                self.updateServerURL()
            } catch {
                print("Erro ao iniciar servidor: \(error)")
            }
        }
    }

    public func stopStream() {
        Task {
            await captureService.stopCapture()
            serverService.stop()
            advertiserService.stopAdvertising()
            self.isStreaming = false
            self.isPaused = false
            self.streamState.reset()
            self.streamStartedAt = nil
            self.latestPreviewImage = nil
        }
    }

    /// Congela a imagem para os alunos sem encerrar a transmissão: o streamer MJPEG continua
    /// reenviando o último frame recebido, então basta parar de alimentá-lo com frames novos.
    public func togglePause() {
        isPaused.toggle()
        streamState.setPaused(isPaused)
        serverService.broadcastControlMessage(type: isPaused ? "STREAM_PAUSED" : "STREAM_RESUMED", payload: nil)
    }

    private func updateServerURL() {
        let ip = serverService.localIPAddress
        self.serverURLString = "http://\(ip):\(serverService.port)"
    }
}

// MARK: - FrameReceiverProtocol
extension MainViewModel: FrameReceiverProtocol {
    /// Encaminha direto para o encoder, sem passar pela MainActor: saltar de thread a cada quadro
    /// adiciona latência e ainda segura os buffers do pool da captura.
    public nonisolated func didReceiveSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        encoderService.encode(sampleBuffer: sampleBuffer)
    }
}

// MARK: - EncodedFrameReceiverProtocol
extension MainViewModel: EncodedFrameReceiverProtocol {
    public nonisolated func didReceiveEncodedFrame(data: Data, isKeyFrame: Bool) {
        guard !streamState.isPaused else { return }

        // broadcastFrame é thread-safe; só a atualização da prévia precisa da main thread.
        serverService.broadcastFrame(data)

        guard streamState.shouldUpdatePreview() else { return }
        Task { @MainActor in
            self.latestPreviewImage = NSImage(data: data)
        }
    }
}

/// Estado compartilhado entre a MainActor e a thread de captura, protegido por lock.
public final class StreamRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var lastPreviewUpdate: Date = .distantPast

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    public func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    /// Limita a prévia local a ~2 fps — ela é só um retorno visual para o professor
    /// e não deve competir com a transmissão pelos recursos da máquina.
    public func shouldUpdatePreview() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPreviewUpdate) > 0.5 else { return false }
        lastPreviewUpdate = now
        return true
    }

    public func reset() {
        lock.lock()
        paused = false
        lastPreviewUpdate = .distantPast
        lock.unlock()
    }
}

// MARK: - CaptureLifecycleObserverProtocol
extension MainViewModel: CaptureLifecycleObserverProtocol {
    /// A captura caiu sozinha: encerra a sessão de forma limpa, avisa o professor na
    /// interface e conta aos alunos, em vez de deixar todo mundo com a imagem congelada.
    public func captureDidStopUnexpectedly(reason: String) {
        guard isStreaming else { return }

        streamErrorMessage = reason

        // O servidor continua no ar de propósito: assim os alunos recebem o aviso,
        // seguem no chat e voltam a ver a aula quando o professor reiniciar — em vez
        // de caírem para a tela de "Reconectando" sem saber o que aconteceu.
        serverService.broadcastControlMessage(type: "STREAM_ENDED", payload: ["reason": reason])

        isStreaming = false
        isPaused = false
        streamState.reset()
        streamStartedAt = nil
        latestPreviewImage = nil
    }
}

// MARK: - ChatObserverProtocol
extension MainViewModel: ChatObserverProtocol {
    public nonisolated func didReceiveChatMessage(_ message: ChatMessage) {
        Task { @MainActor in
            self.chatManager.addMessage(message)
        }
    }
}

// MARK: - HandRaiseObserverProtocol
extension MainViewModel: HandRaiseObserverProtocol {
    public nonisolated func didToggleHandRaise(clientId: String, displayName: String, isRaised: Bool) {
        Task { @MainActor in
            self.clientManager.setHandRaised(clientId: clientId, displayName: displayName, isRaised: isRaised)
        }
    }
}

// MARK: - StudentPresenceObserverProtocol
extension MainViewModel: StudentPresenceObserverProtocol {
    public nonisolated func didIdentifyStudent(clientId: String, name: String, matricula: String) {
        Task { @MainActor in
            self.clientManager.identify(clientId: clientId, name: name, matricula: matricula)
        }
    }

    public nonisolated func didChangeWatching(clientId: String, isWatching: Bool) {
        Task { @MainActor in
            self.clientManager.setWatching(clientId: clientId, isWatching: isWatching)
        }
    }
}

// MARK: - ClientObserverProtocol
extension MainViewModel: ClientObserverProtocol {
    public nonisolated func didClientConnect(_ client: ConnectedClient) {
        Task { @MainActor in
            // Preserva o id vindo do handshake: é a chave usada para levantar a mão depois.
            self.clientManager.addOrUpdateClient(client)
        }
    }

    public nonisolated func didClientDisconnect(clientId: String) {
        Task { @MainActor in
            self.clientManager.removeClient(id: clientId)
        }
    }
}