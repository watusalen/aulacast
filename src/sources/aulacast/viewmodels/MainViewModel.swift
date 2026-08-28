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

    /// Verdadeiro depois que o aviso do macOS já foi disparado nesta execução.
    ///
    /// Enquanto o app não reabre, `isGranted()` continua falso **mesmo depois de o professor
    /// autorizar** — a permissão não se aplica a um processo que já estava rodando. Pedir de
    /// novo a cada clique em "Iniciar Transmissão" reabria o mesmo aviso indefinidamente:
    /// era esse o looping. Uma vez pedido, o único passo que resta é reabrir o aplicativo.
    private var jaPediuPermissao = false

    /// Liga a tela que explica a permissão de Gravação de Tela.
    ///
    /// É estado do modelo, e não da view, porque quem descobre que falta permissão é a
    /// tentativa de transmitir. Antes a tela era decidida uma única vez na abertura: quem
    /// dispensasse com "Agora não" nunca mais a via, mesmo clicando em transmitir de novo.
    @Published public var needsScreenRecordingPermission: Bool = false

    /// Compartilhado com a thread de captura (que não pode tocar em estado da MainActor).
    public let streamState = StreamRuntimeState()

    /// Desligar o chat já barrava as mensagens no servidor, mas em silêncio: o aluno digitava,
    /// apertava Enter e o texto sumia sem explicação, dando a impressão de que o botão não
    /// funcionava. Avisar os alunos na hora deixa o campo inativo na tela deles.
    @Published public var isChatEnabled: Bool = true {
        didSet {
            serverService.isChatEnabled = isChatEnabled
            serverService.broadcastControlMessage(
                type: "CHAT_STATE",
                payload: ["enabled": isChatEnabled ? "true" : "false"]
            )
        }
    }

    public let captureService: any ScreenCaptureProtocol
    public let advertiserService: ServiceAdvertiserProtocol

    // Acessados a cada quadro pela thread de captura; ambos são imutáveis e protegidos
    // internamente por lock, então não devem exigir salto para a MainActor.
    nonisolated(unsafe) public let encoderService: VideoEncoderProtocol
    nonisolated(unsafe) public let serverService: NetworkServerProtocol

    /// Mantém a transmissão viva quando o professor troca de Mesa ou muda de aplicativo.
    public let systemActivity: SystemActivityProtocol

    public let permission: ScreenRecordingPermissionProtocol

    public let chatManager: ChatManagerService
    public let clientManager: ClientManagerService

    private var cancellables = Set<AnyCancellable>()

    public init(
        captureService: any ScreenCaptureProtocol = ScreenCaptureService(),
        encoderService: VideoEncoderProtocol = MJPEGFrameEncoder(),
        serverService: NetworkServerProtocol = NetworkListenerService(port: 8080, webAssetsPath: WebAssetsPathResolver.resolve()),
        // Sem porta fixa aqui: o Bonjour precisa anunciar a porta em que o servidor de fato
        // subiu. Repetir o 8080 neste ponto era um número solto que passaria a mentir para a
        // rede assim que alguém trocasse a porta do servidor.
        advertiserService: ServiceAdvertiserProtocol? = nil,
        systemActivity: SystemActivityProtocol = SystemActivityService(),
        permission: ScreenRecordingPermissionProtocol = ScreenRecordingPermissionService(),
        chatManager: ChatManagerService = ChatManagerService(),
        clientManager: ClientManagerService = ClientManagerService()
    ) {
        self.captureService = captureService
        self.encoderService = encoderService
        self.serverService = serverService
        self.advertiserService = advertiserService ?? BonjourAdvertiserService(port: serverService.port)
        self.systemActivity = systemActivity
        self.permission = permission
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

            // Sem permissão nem vale tentar: o ScreenCaptureKit falharia e o professor
            // ficaria com um "AO VIVO" que não transmite nada.
            //
            // Quem conduz daqui é o macOS. `request()` faz o sistema exibir o próprio aviso
            // ("Abrir Ajustes do Sistema" / "Negar"), levar aos Ajustes e, depois do professor
            // autorizar, oferecer "Encerrar e Reabrir" — que é o único jeito de a permissão
            // valer, porque ela não se aplica a um processo já em execução.
            //
            // O AulaCast não desenha nenhuma tela por cima disso. A versão anterior mostrava
            // um painel próprio que disparava o aviso nativo, e o professor acabava em dois
            // pedidos empilhados que reapareciam em looping. Aqui só fica um recado no painel,
            // para o caso de ele ter escolhido "Negar" ou "Mais Tarde".
            guard permission.isGranted() else {
                self.needsScreenRecordingPermission = true

                if jaPediuPermissao {
                    // O aviso do macOS já apareceu nesta execução. Repeti-lo não muda nada:
                    // daqui em diante só reabrir o aplicativo resolve.
                    self.streamErrorMessage =
                        "Se você já autorizou o AulaCast, reabra o aplicativo para valer. "
                        + "O macOS não aplica essa permissão a um app que já estava aberto."
                } else {
                    jaPediuPermissao = true
                    permission.request()
                    self.streamErrorMessage =
                        "Autorize o AulaCast em Gravação de Tela e reabra o aplicativo."
                }
                return
            }

            // A tentativa vingou: se a tela ainda estava pedindo autorização, não pede mais.
            self.needsScreenRecordingPermission = false

            await captureService.startCapture()

            // A captura pode falhar mesmo com a permissão concedida (monitor desconectado,
            // janela fechada no meio do caminho, permissão concedida sem reabrir o app).
            // Seguir daqui subia o servidor e marcava `isStreaming`, então a tela mostrava
            // "TRANSMITINDO AO VIVO" com o cronômetro correndo enquanto a turma via uma
            // imagem vazia — o pior erro possível, porque não parece erro nenhum.
            guard captureService.isRecording else {
                self.streamErrorMessage = captureService.errorMessage
                    ?? "Não foi possível iniciar a captura da tela."
                return
            }

            do {
                try serverService.start()
                advertiserService.startAdvertising()
                self.systemActivity.beginTransmission(
                    reason: "Transmitindo a aula para os alunos na rede local"
                )
                self.isStreaming = true
                self.isPaused = false
                self.streamState.reset()
                self.streamStartedAt = Date()
                self.updateServerURL()

                // Avisa quem já estava conectado que a aula voltou.
                //
                // Quando a captura cai sozinha, o servidor segue no ar de propósito e os
                // alunos recebem STREAM_ENDED: a página deles para de pedir vídeo e mostra
                // o motivo. Sem este aviso de volta, o WebSocket nunca cai, nada reinicia o
                // vídeo e a turma inteira ficava na tela de "Transmissão encerrada" mesmo
                // com o professor já transmitindo de novo — só recarregando a página resolvia.
                serverService.broadcastControlMessage(type: "STREAM_STARTED", payload: nil)
            } catch {
                // O servidor não subiu: desfaz a captura em vez de deixá-la rodando à toa.
                await captureService.stopCapture()
                self.streamErrorMessage = "Não foi possível abrir o servidor na porta \(serverService.port)."
            }
        }
    }

    public func stopStream() {
        Task {
            await captureService.stopCapture()
            serverService.stop()
            advertiserService.stopAdvertising()
            self.systemActivity.endTransmission()
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

        // A proteção contra o sono continua segurada de propósito, e é o mesmo motivo pelo
        // qual o servidor segue no ar: a turma continua conectada.
        //
        // Soltá-la aqui desfazia justamente o que as linhas acima tentam fazer. Nesta
        // máquina o macOS está configurado para dormir em 1 minuto ocioso — então, um
        // minuto depois da queda, o Mac dormia, todas as conexões caíam e os alunos iam
        // para "Reconectando" enquanto o professor ainda estava lendo o aviso do erro.
        // Quem encerra a sessão de verdade é "Parar Transmissão", e é lá que ela é liberada.
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