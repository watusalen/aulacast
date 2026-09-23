import Foundation
import SwiftUI
import Combine
import CoreMedia
import AppKit
import Network

@MainActor
public final class MainViewModel: ObservableObject {
    @Published public var isStreaming: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var serverURLString: String = "http://127.0.0.1:8080"

    /// O endereço como a turma digita: sem o "http://".
    ///
    /// O navegador completa sozinho — com endereço de rede local ele nem avisa: o Chrome
    /// tenta HTTPS, não consegue e cai para HTTP, e o aviso "Ask-before-HTTP" (padrão a
    /// partir do Chrome 154) não aparece para IP local. Menos coisa para copiar da lousa.
    /// O botão de copiar continua levando o link completo, que precisa do "http://" para
    /// virar link clicável quando colado num grupo ou documento.
    public var displayAddress: String {
        serverURLString.replacingOccurrences(of: "http://", with: "")
    }
    @Published public var streamStartedAt: Date?
    @Published public var latestPreviewImage: NSImage?

    /// Servidor no ar e alunos conectados, mesmo que a captura tenha caído.
    ///
    /// Depois que a captura cai sozinha `isStreaming` vira falso, mas o servidor e a
    /// proteção contra o sono continuam segurados de propósito. Sem este estado o painel só
    /// oferecia "Iniciar", e não havia como encerrar a sessão: o Mac nunca mais dormia e a
    /// porta seguia aberta até o app fechar.
    @Published public private(set) var isSessionOpen: Bool = false

    /// Arquivos que a turma pode baixar agora, na ordem em que foram compartilhados.
    @Published public private(set) var sharedFiles: [SharedFile] = []

    /// Downloads em andamento e concluídos de cada arquivo, pelo id.
    ///
    /// Compartilhar não envia nada: o arquivo fica no Mac e cada aluno baixa direto dele
    /// quando toca no link. Por isso o que o professor precisa ver não é uma barra de
    /// "enviando", e sim quem está baixando e quem já baixou.
    @Published public private(set) var fileDownloadStats: [String: FileDownloadStats] = [:]

    /// Recado sobre o último compartilhamento (uma pasta escolhida, um arquivo ilegível).
    @Published public var sharedFilesNotice: String?

    /// Um início em andamento (esperando a permissão, o sistema e o ScreenCaptureKit).
    /// O botão fica desabilitado nesse meio-tempo: um duplo clique criava dois streams.
    @Published public private(set) var isStarting: Bool = false

    /// A pausa atual foi posta pelo app porque a janela transmitida sumiu, e não pelo
    /// professor. Só essa pausa é desfeita sozinha quando a janela volta.
    private var pausadoPorqueAJanelaSumiu = false

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

    /// Avisa quando a rede muda (trocar de Wi-Fi, plugar cabo, o roteador renovar o IP).
    ///
    /// Sem isto o endereço no painel só era recalculado ao iniciar a transmissão. O professor
    /// que abrisse o aplicativo em casa e chegasse na escola veria o endereço de casa na tela.
    private let monitorDeRede = NWPathMonitor()
    private let filaDoMonitor = DispatchQueue(label: "br.com.ifpi.aulacast.rede")

    public init(
        captureService: any ScreenCaptureProtocol = ScreenCaptureService(),
        encoderService: VideoEncoderProtocol = MJPEGFrameEncoder(),
        serverService: NetworkServerProtocol = NetworkListenerService(port: 8080, webAssetsPath: WebAssetsPathResolver.resolve()),
        // O anúncio Bonjour sai do próprio servidor, na porta dele: não há uma segunda
        // porta para manter em sincronia.
        advertiserService: ServiceAdvertiserProtocol? = nil,
        systemActivity: SystemActivityProtocol = SystemActivityService(),
        permission: ScreenRecordingPermissionProtocol = ScreenRecordingPermissionService(),
        chatManager: ChatManagerService = ChatManagerService(),
        clientManager: ClientManagerService = ClientManagerService()
    ) {
        self.captureService = captureService
        self.encoderService = encoderService
        self.serverService = serverService
        self.advertiserService = advertiserService
            ?? (serverService as? BonjourHostProtocol).map { BonjourAdvertiserService(servidor: $0) }
            ?? SemAnuncioService()
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
        self.serverService.clientObserver = self
        self.serverService.isChatEnabled = self.isChatEnabled
        self.serverService.onFailure = { [weak self] mensagem in
            Task { @MainActor in self?.serverDidFail(mensagem) }
        }
        self.serverService.onFileDownloadUpdate = { [weak self] estatisticas in
            Task { @MainActor in
                // Um download que termina depois de o arquivo sair da lista não o traz de volta.
                guard let self, self.sharedFiles.contains(where: { $0.id == estatisticas.fileId }) else { return }
                self.fileDownloadStats[estatisticas.fileId] = estatisticas
            }
        }

        self.updateServerURL()

        monitorDeRede.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.updateServerURL() }
        }
        monitorDeRede.start(queue: filaDoMonitor)
    }

    deinit {
        monitorDeRede.cancel()
    }

    /// Disponibiliza arquivos para a turma baixar. Qualquer tipo serve; pastas ficam de fora
    /// (o navegador baixa arquivos, não pastas — basta compactá-la antes).
    public func shareFiles(_ urls: [URL]) {
        var pulados: [String] = []
        var novos = sharedFiles
        for url in urls {
            // O macOS guarda o nome com o acento separado da letra (NFD). Mandado assim, o
            // "ó" aparece em alguns sistemas como "o" seguido de um acento solto.
            let nome = url.lastPathComponent.precomposedStringWithCanonicalMapping
            var ehPasta: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &ehPasta), !ehPasta.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let tamanho = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            else {
                pulados.append(nome)
                continue
            }
            // O mesmo arquivo escolhido de novo não vira uma segunda linha na lista.
            guard !novos.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            novos.append(SharedFile(name: nome, url: url, size: tamanho.int64Value))
        }

        sharedFilesNotice = pulados.isEmpty ? nil
            : "Não foi possível compartilhar: \(pulados.joined(separator: ", ")). "
              + "Pastas precisam ser compactadas antes."
        guard novos != sharedFiles else { return }
        sharedFiles = novos
        serverService.updateSharedFiles(novos)
    }

    /// Tira o arquivo da lista: some da página dos alunos e o link para de funcionar.
    public func removeSharedFile(id: String) {
        sharedFiles.removeAll { $0.id == id }
        fileDownloadStats.removeValue(forKey: id)
        serverService.updateSharedFiles(sharedFiles)
    }

    public func sendProfMessage(text: String) {
        chatManager.sendProfMessage(text: text)
        if let lastMsg = chatManager.messages.last, lastMsg.isProf {
            serverService.broadcastChatMessage(lastMsg)
        }
    }

    public func startStream() {
        guard !isStarting, !isStreaming else { return }
        isStarting = true
        Task {
            defer { self.isStarting = false }
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
                self.isSessionOpen = true
                self.isPaused = false
                self.pausadoPorqueAJanelaSumiu = false
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

    /// O servidor caiu depois de subir (porta ocupada por outro app, por exemplo).
    /// Sem alunos para receber nada, não há sessão: encerra tudo e mostra o motivo.
    private func serverDidFail(_ mensagem: String) {
        guard isSessionOpen || isStreaming else { return }
        stopStream()
        streamErrorMessage = mensagem
    }

    public func stopStream() {
        Task {
            await captureService.stopCapture()
            serverService.stop()
            advertiserService.stopAdvertising()
            self.systemActivity.endTransmission()
            self.isStreaming = false
            self.isSessionOpen = false
            self.isPaused = false
            self.pausadoPorqueAJanelaSumiu = false
            self.streamState.reset()
            self.streamStartedAt = nil
            self.latestPreviewImage = nil
        }
    }

    /// Congela a imagem para os alunos sem encerrar a transmissão: o streamer MJPEG continua
    /// reenviando o último frame recebido, então basta parar de alimentá-lo com frames novos.
    public func togglePause() {
        // O professor assumiu: a pausa passa a ser dele e não se desfaz sozinha.
        pausadoPorqueAJanelaSumiu = false
        alternarPausa()
    }

    private func alternarPausa() {
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
        pausadoPorqueAJanelaSumiu = false
        streamState.reset()
        streamStartedAt = nil
        latestPreviewImage = nil
    }

    public func captureDidReportError(_ message: String) {
        streamErrorMessage = message
    }

    /// Pausa em vez de mostrar a última imagem congelada como se fosse ao vivo. Não troca
    /// para o monitor inteiro por conta própria: o professor escolheu uma janela justamente
    /// para não mostrar o resto da tela.
    public func captureSourceDidDisappear(sourceName: String) {
        guard isStreaming else { return }
        streamErrorMessage = "A janela “\(sourceName)” foi fechada ou minimizada, e a transmissão "
            + "foi pausada. Reabra a janela ou escolha outra fonte para continuar."
        if !isPaused {
            alternarPausa()
            pausadoPorqueAJanelaSumiu = true
        }
    }

    public func captureSourceIsAvailableAgain() {
        guard pausadoPorqueAJanelaSumiu else { return }
        pausadoPorqueAJanelaSumiu = false
        if isPaused { alternarPausa() }
        streamErrorMessage = nil
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

// MARK: - StudentPresenceObserverProtocol
extension MainViewModel: StudentPresenceObserverProtocol {
    public nonisolated func didIdentifyStudent(clientId: String, name: String) {
        Task { @MainActor in
            self.clientManager.identify(clientId: clientId, name: name)
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