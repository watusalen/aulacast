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

    /// O endereço como a turma digita.
    ///
    /// Enquanto a transmissão está no ar, mostra `<nome>:<porta>` com o nome mDNS que o
    /// `MDNSHostnameService` registrou e o sistema **confirmou** (`aulacast.local` ou, se
    /// outro professor já o usa na rede, `aulacast-2.local` etc.) — funciona em
    /// Chrome/Edge/Safari sem nenhuma configuração. Antes da sessão abrir, ou enquanto
    /// nenhum nome estiver confirmado, mostra o IP numérico: ele nunca leva a turma à aula
    /// de outro professor.
    ///
    /// Sem a porta (`aulacast.local` puro) exigiria o servidor escutar na porta 80, que só
    /// root abre no macOS — chegou a ser tentado via `pf`, mas a única forma de fazer valer
    /// de verdade é substituir o conjunto de regras de firewall do sistema inteiro, o que
    /// não vale o risco para este app.
    public var displayAddress: String {
        if isSessionOpen, let nome = mdnsHostname {
            return "\(nome):\(serverService.port)"
        }
        return serverURLString.replacingOccurrences(of: "http://", with: "")
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

    /// Nome `.local` confirmado pelo mDNS para esta aula, sem a porta; `nil` até confirmar.
    @Published public private(set) var mdnsHostname: String?
    /// Última configuração vista, para o arquivo de métricas registrar só o que mudou.
    fileprivate var configAnterior = ConfiguracaoDeMetricas()
    fileprivate let caixaDeConfiguracao = CaixaDeConfiguracao()

    /// Arquivos que a turma pode baixar agora, na ordem em que foram compartilhados.
    @Published public private(set) var sharedFiles: [SharedFile] = []

    /// Downloads em andamento e concluídos de cada arquivo, pelo id.
    ///
    /// Compartilhar não envia nada: o arquivo fica no Mac e cada aluno baixa direto dele
    /// quando toca no link. Por isso o que o professor precisa ver não é uma barra de
    /// "enviando", e sim quem já baixou (a tela mostra só os concluídos).
    @Published public private(set) var fileDownloadStats: [String: FileDownloadStats] = [:]

    /// Quantas mensagens de alunos chegaram desde que o app abriu.
    ///
    /// Serve para o contador de não lidas do painel: contar pelo tamanho do histórico não
    /// funciona, porque ele guarda só as últimas 500 e para de crescer.
    @Published public private(set) var studentMessagesReceived: Int = 0

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
            registrarEventoDoChat()
        }
    }

    /// Desligado por padrão: mensagem de aluno continua só com o professor. O campo de
    /// escrever continua igual dos dois lados — o que muda é quem recebe depois, e é
    /// exatamente isso que o aviso fixo no topo do chat do aluno precisa refletir na hora,
    /// não só quando ele mandar a próxima mensagem (ou pior, nunca, se não mandar nenhuma).
    @Published public var isStudentChatVisibleToClass: Bool = false {
        didSet {
            serverService.isStudentChatVisibleToClass = isStudentChatVisibleToClass
            serverService.broadcastControlMessage(
                type: "CHAT_VISIBILITY",
                payload: ["visible": isStudentChatVisibleToClass ? "true" : "false"]
            )
            registrarEventoDoChat()
        }
    }

    public let captureService: any ScreenCaptureProtocol
    public let advertiserService: ServiceAdvertiserProtocol

    // Acessados a cada quadro pela thread de captura; ambos são imutáveis e protegidos
    // internamente por lock, então não devem exigir salto para a MainActor.
    nonisolated(unsafe) public let encoderService: VideoEncoderProtocol
    nonisolated(unsafe) public let serverService: NetworkServerProtocol

    /// Caminho H.264/fMP4 em paralelo ao MJPEG (`encoderService`), enquanto o cliente não
    /// decide sozinho qual dos dois usar — ver PLANO-COMPRESSAO-DE-VIDEO.md. Os dois recebem o
    /// mesmo `CMSampleBuffer`; o aluno é quem escolhe a rota (`/stream` ou `/stream.mp4`), então
    /// o servidor mantém as duas alimentadas o tempo todo.
    nonisolated(unsafe) private let h264EncoderService = H264FrameEncoder()
    nonisolated(unsafe) private let fmp4Packager = FMP4Packager()

    /// Mantém a transmissão viva quando o professor troca de Mesa ou muda de aplicativo.
    public let systemActivity: SystemActivityProtocol

    public let permission: ScreenRecordingPermissionProtocol

    public let chatManager: ChatManagerService
    public let clientManager: ClientManagerService
    /// Tempo de cada aluno na aula (RF-20).
    public let ledger: AttendanceLedger

    /// Aluno cujo painel de tempo está aberto (id da conexão); `nil` com o painel fechado.
    @Published public var alunoAberto: String?

    private var cancellables = Set<AnyCancellable>()

    /// Registra `aulacast.local` na rede enquanto a transmissão está no ar.
    private let mdnsService: HostnameAdvertisingProtocol
    /// IP para o qual o nome `.local` foi registrado; `nil` fora da sessão.
    private var ipDoNome: String?


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
        hostnameService: HostnameAdvertisingProtocol = MDNSHostnameService(),
        chatManager: ChatManagerService = ChatManagerService(),
        clientManager: ClientManagerService = ClientManagerService(),
        ledger: AttendanceLedger = AttendanceLedger()
    ) {
        self.captureService = captureService
        self.encoderService = encoderService
        self.serverService = serverService
        self.advertiserService = advertiserService
            ?? (serverService as? BonjourHostProtocol).map { BonjourAdvertiserService(servidor: $0) }
            ?? SemAnuncioService()
        self.systemActivity = systemActivity
        self.permission = permission
        self.mdnsService = hostnameService
        self.chatManager = chatManager
        self.clientManager = clientManager
        self.ledger = ledger

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
        self.h264EncoderService.h264OutputReceiver = self.fmp4Packager
        self.fmp4Packager.outputReceiver = self
        self.serverService.onVideoViewerNeedsKeyFrame = { [weak self] in
            self?.h264EncoderService.forceNextKeyFrame()
        }
        self.serverService.chatObserver = self
        self.serverService.presenceObserver = self
        self.serverService.clientObserver = self
        self.serverService.handRaiseObserver = self
        self.serverService.isChatEnabled = self.isChatEnabled
        self.serverService.isStudentChatVisibleToClass = self.isStudentChatVisibleToClass
        self.mdnsService.onHostnameChange = { [weak self] nome in
            Task { @MainActor in
                self?.registrarEventoDoMDNS(nome)
                self?.mdnsHostname = nome
            }
        }
        observarConfiguracaoDaCaptura(captureService)
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

    /// Fixa uma mensagem do professor no topo do chat da turma. Fixar outra substitui.
    public func pinMessage(_ message: ChatMessage) {
        guard chatManager.pin(message) else { return }
        serverService.updatePinnedMessage(message.text)
    }

    public func unpinMessage() {
        guard chatManager.unpin() else { return }
        serverService.updatePinnedMessage(nil)
    }

    /// O professor atendeu o aluno e abaixa a mão dele, como o "Abaixar a mão" do Meet.
    /// A lista muda na hora; o aviso vai só para aquele aluno, para a mão sumir da tela dele.
    public func lowerHand(clientId: String) {
        guard clientManager.clients.first(where: { $0.id == clientId })?.isHandRaised == true else { return }
        clientManager.setHandRaised(clientId: clientId, isRaised: false)
        serverService.lowerHand(clientId: clientId)
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

            // Sessão nova de verdade — não uma retomada depois da captura cair sozinha, que
            // mantém `isSessionOpen` true com o servidor de pé enquanto o professor clica em
            // "Iniciar Transmissão" de novo (ver `serverService.start()`). Só numa sessão nova
            // o histórico permanente de "quantos alunos passaram pela aula" deve zerar; numa
            // retomada, quem já baixou ou já entrou continua contando.
            let éSessãoNova = !isSessionOpen

            do {
                prepararMetricasDaSessao()
                try serverService.start()
                advertiserService.startAdvertising()
                // A taxa de bits do H.264 sai do fps escolhido; vale na criação da sessão do encoder.
                h264EncoderService.framesPerSecond = captureService.frameRate
                let ipAtual = serverService.localIPAddress
                mdnsService.start(ip: ipAtual)
                ipDoNome = ipAtual
                self.systemActivity.beginTransmission(
                    reason: "Transmitindo a aula para os alunos na rede local"
                )
                self.isStreaming = true
                self.isSessionOpen = true
                if éSessãoNova {
                    clientManager.reiniciarHistoricoDaAula()
                }
                self.isPaused = false
                self.pausadoPorqueAJanelaSumiu = false
                ledger.reset()
                ledger.setAccruing(true)
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
            // Antes de parar o servidor: um quadro-chave em voo entre os dois resets gravaria um
            // segmento de inicialização velho no servidor.
            self.fmp4Packager.reset()
            serverService.stop()
            advertiserService.stopAdvertising()
            mdnsService.stop()
            self.mdnsHostname = nil
            self.ipDoNome = nil
            // Sessão seguinte começa do zero (o empacotador já foi zerado acima).
            self.h264EncoderService.forceNextKeyFrame()
            self.systemActivity.endTransmission()
            self.ledger.setAccruing(false)
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
        alternarPausa(origem: "professor")
    }

    private func alternarPausa(origem: String) {
        isPaused.toggle()
        serverService.registrarEventoDeSessao(isPaused ? "pausa" : "retomada", ["origem": origem])
        streamState.setPaused(isPaused)
        ledger.setAccruing(!isPaused)
        // Ao retomar, o primeiro quadro tem de ser um quadro-chave: a referência dos alunos é a
        // de antes da pausa, e a tela pode ser outra.
        if !isPaused { h264EncoderService.forceNextKeyFrame() }
        serverService.broadcastControlMessage(type: isPaused ? "STREAM_PAUSED" : "STREAM_RESUMED", payload: nil)
    }

    /// Relê o IP da máquina e, se a sessão estiver aberta, refaz o nome `.local` quando ele mudou.
    public func updateServerURL() {
        let ip = serverService.localIPAddress
        if isSessionOpen, let registrado = ipDoNome, registrado != ip {
            serverService.registrarEventoDeSessao("rede", ["de": registrado, "para": ip])
        }
        self.serverURLString = "http://\(ip):\(serverService.port)"

        // Trocou de rede no meio da aula: o nome `.local` seguia apontando para o IP antigo, e o
        // painel, que prefere o nome, passava a mostrar um endereço que não leva a lugar nenhum.
        // Retira o nome e o registra de novo no IP novo; até confirmar, o painel mostra o IP.
        if isSessionOpen, let registrado = ipDoNome, registrado != ip {
            mdnsHostname = nil
            mdnsService.stop()
            mdnsService.start(ip: ip)
            ipDoNome = ip
        }
    }
}

// MARK: - FrameReceiverProtocol
extension MainViewModel: FrameReceiverProtocol {
    /// Encaminha direto para o encoder, sem passar pela MainActor: saltar de thread a cada quadro
    /// adiciona latência e ainda segura os buffers do pool da captura.
    public nonisolated func didReceiveSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Em pausa nenhum codificador recebe quadro. O H.264 não pode "assistir" à pausa: ele
        // usa cada quadro como referência do seguinte, e quem a descarta só na saída entrega,
        // ao retomar, diferenças calculadas sobre imagens que o aluno nunca recebeu — um
        // fantasma do que o professor mostrou durante a pausa, visível até o próximo quadro-chave.
        guard !streamState.isPaused else { return }
        // O H.264 vai primeiro: o JPEG, feito na mesma thread, não deve somar-se ao atraso dele.
        h264EncoderService.encode(sampleBuffer: sampleBuffer)
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

// MARK: - FMP4FragmentReceiverProtocol
extension MainViewModel: FMP4FragmentReceiverProtocol {
    public nonisolated func didReceiveFragment(_ data: Data, isInitSegment: Bool, isKeyFrame: Bool) {
        // Mesmo portão do MJPEG: com a aula pausada, ninguém recebe atualização nova em
        // nenhuma das duas rotas — é o que sustenta o "modo pausado" sem tratamento especial.
        // O segmento de inicialização passa mesmo em pausa: descartá-lo deixaria o servidor com
        // um `avcC` velho enquanto o empacotador acha que já o enviou.
        guard isInitSegment || !streamState.isPaused else { return }
        serverService.broadcastVideoFragment(data, isInitSegment: isInitSegment, isKeyFrame: isKeyFrame)
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

// MARK: - Arquivo de métricas da sessão (só depuração)
extension MainViewModel {
    /// Antes de subir o servidor: o que o `inicio` traz da captura (sem títulos de janela) e de onde
    /// o `fim` tira os tempos por aluno.
    fileprivate func prepararMetricasDaSessao() {
        let res = captureService.resolution, fps = captureService.frameRate
        let alvo = H264FrameEncoder.taxaMediaBps(largura: Int(res.width), altura: Int(res.height), fps: fps)
        configAnterior = configuracaoAtual()
        caixaDeConfiguracao.definir(configDeCaptura())
        serverService.configurarSessaoDeMetricas(contexto: [
            "resolucao": res.rawValue, "fps": fps, "taxaAlvoMbps": Double(alvo) / 1_000_000,
            "fonte": configAnterior.fonte, "appsOcultos": configAnterior.ocultos
        ], tempos: { [ledger] in ledger.temposPorNome() }, configuracao: { [caixa = caixaDeConfiguracao, encoder = h264EncoderService] in
            var c = caixa.ler()
            if let a = encoder.aplicado { c.taxaAlvoBps = a.taxaBps; c.fpsEncoder = a.fps }
            return c
        })
    }

    /// Genérico para abrir o `any ScreenCaptureProtocol` e alcançar o `objectWillChange` dele.
    fileprivate func observarConfiguracaoDaCaptura<C: ScreenCaptureProtocol>(_ captura: C) {
        captura.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.registrarMudancaDeConfiguracao() }
            .store(in: &cancellables)
    }

    fileprivate func configuracaoAtual() -> ConfiguracaoDeMetricas {
        let tipo = captureService.selectedSource?.type
        return ConfiguracaoDeMetricas(resolucao: captureService.resolution.rawValue, fps: captureService.frameRate,
                                      fonte: tipo == .window ? "janela" : "monitor", ocultos: captureService.appsOcultos.count)
    }

    fileprivate func configDeCaptura() -> ConfigDeCaptura {
        let res = captureService.resolution, fps = captureService.frameRate
        return ConfigDeCaptura(resolucao: res.rawValue, fpsAlvo: fps,
                               taxaAlvoBps: H264FrameEncoder.taxaMediaBps(largura: Int(res.width), altura: Int(res.height), fps: fps),
                               fonte: captureService.selectedSource?.type == .window ? "janela" : "monitor")
    }

    fileprivate func registrarMudancaDeConfiguracao() {
        caixaDeConfiguracao.definir(configDeCaptura())
        let agora = configuracaoAtual()
        defer { configAnterior = agora }
        guard isSessionOpen, agora != configAnterior else { return }
        if agora.resolucao != configAnterior.resolucao || agora.fps != configAnterior.fps || agora.fonte != configAnterior.fonte {
            // Um único evento por mudança (o bloco de configuração sobe uma vez), só com os campos que mudaram.
            var dados: [String: Any] = [:]
            if agora.resolucao != configAnterior.resolucao { dados["resolucaoDe"] = configAnterior.resolucao; dados["resolucaoPara"] = agora.resolucao }
            if agora.fps != configAnterior.fps { dados["fpsDe"] = configAnterior.fps; dados["fpsPara"] = agora.fps }
            if agora.fonte != configAnterior.fonte { dados["fonteDe"] = configAnterior.fonte; dados["fontePara"] = agora.fonte }
            // O que o encoder usa de verdade: ele só lê fps e taxa ao criar a sessão.
            let aplicado = h264EncoderService.aplicado
            let escolhida = configDeCaptura()
            dados["taxaAlvoBpsAplicada"] = aplicado?.taxaBps ?? NSNull()
            dados["encoderAtualizado"] = aplicado != nil && aplicado?.fps == escolhida.fpsAlvo && aplicado?.taxaBps == escolhida.taxaAlvoBps
            serverService.registrarEventoDeSessao("config", dados)
        }
        if agora.ocultos != configAnterior.ocultos {
            serverService.registrarEventoDeSessao("apps", ["ocultos": agora.ocultos])
        }
    }

    fileprivate func registrarEventoDoChat() {
        serverService.registrarEventoDeSessao("chat", ["ligado": isChatEnabled, "alunosVeemUnsAosOutros": isStudentChatVisibleToClass])
    }

    /// `confirmado` com nome novo, `perdido` com `nil`; um nome diferente do anterior sem ter sido
    /// perdido é o sistema renomeando por conflito (`aulacast-2.local`).
    fileprivate func registrarEventoDoMDNS(_ nome: String?) {
        let estado: String
        if nome == nil { estado = "perdido" } else if let anterior = mdnsHostname, anterior != nome { estado = "conflito" } else { estado = "confirmado" }
        serverService.registrarEventoDeSessao("mdns", ["estado": estado, "nome": nome ?? ""])
    }
}

struct ConfiguracaoDeMetricas: Equatable {
    var resolucao = "", fps = 0, fonte = "monitor", ocultos = 0
}

// MARK: - CaptureLifecycleObserverProtocol
extension MainViewModel: CaptureLifecycleObserverProtocol {
    /// A captura caiu sozinha: encerra a sessão de forma limpa, avisa o professor na
    /// interface e conta aos alunos, em vez de deixar todo mundo com a imagem congelada.
    public func captureDidStopUnexpectedly(reason: String) {
        guard isStreaming else { return }

        // Só a categoria: o texto pode citar o título de uma janela, que não vai para o arquivo.
        serverService.registrarEventoDeSessao("captura", ["motivo": reason.hasPrefix("A janela") ? "janela fechada" : "erro do sistema"])
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
        ledger.setAccruing(false)
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
            alternarPausa(origem: "janela")
            pausadoPorqueAJanelaSumiu = true
        }
    }

    public func captureSourceIsAvailableAgain() {
        guard pausadoPorqueAJanelaSumiu else { return }
        pausadoPorqueAJanelaSumiu = false
        if isPaused { alternarPausa(origem: "janela") }
        streamErrorMessage = nil
    }
}

// MARK: - ChatObserverProtocol
extension MainViewModel: ChatObserverProtocol {
    public nonisolated func didReceiveChatMessage(_ message: ChatMessage) {
        Task { @MainActor in
            self.chatManager.addMessage(message)
            if !message.isProf { self.studentMessagesReceived += 1 }
        }
    }
}

// MARK: - HandRaiseObserverProtocol
extension MainViewModel: HandRaiseObserverProtocol {
    public nonisolated func didToggleHandRaise(clientId: String, displayName: String, isRaised: Bool) {
        Task { @MainActor in
            // O nome já chegou pelo IDENTIFY (é dele que o servidor tira o `displayName`);
            // aqui só muda a mão.
            self.clientManager.setHandRaised(clientId: clientId, isRaised: isRaised)
        }
    }
}

// MARK: - StudentPresenceObserverProtocol
extension MainViewModel: StudentPresenceObserverProtocol {
    public nonisolated func didIdentifyStudent(clientId: String, name: String) {
        Task { @MainActor in
            self.clientManager.identify(clientId: clientId, name: name)
            self.ledger.identified(clientId: clientId, name: name)
        }
    }

    public nonisolated func didChangeWatching(clientId: String, isWatching: Bool) {
        Task { @MainActor in
            self.clientManager.setWatching(clientId: clientId, isWatching: isWatching)
            self.ledger.visibility(clientId: clientId, visible: isWatching)
        }
    }
}

// MARK: - ClientObserverProtocol
extension MainViewModel: ClientObserverProtocol {
    public nonisolated func didClientConnect(_ client: ConnectedClient) {
        Task { @MainActor in
            // Preserva o id vindo do handshake: é a chave usada para identificar o aluno e
            // levantar a mão depois.
            self.clientManager.addOrUpdateClient(client)
            self.ledger.connected(clientId: client.id, ip: client.ipAddress, visible: client.isWatching)
        }
    }

    public nonisolated func didClientDisconnect(clientId: String) {
        Task { @MainActor in
            self.clientManager.removeClient(id: clientId)
            self.ledger.disconnected(clientId: clientId)
            if self.alunoAberto == clientId { self.alunoAberto = nil }
        }
    }
}