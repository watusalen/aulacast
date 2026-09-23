import Foundation
import Network
import CoreWLAN

/// Servico central de escuta de rede e orquestracao HTTP/WebSocket (SRP, DIP, LSP).
public final class NetworkListenerService: NetworkServerProtocol, BonjourHostProtocol {
    public private(set) var isRunning: Bool = false
    public let port: UInt16

    /// Endereço que o professor passa para a turma.
    ///
    /// Consultado na hora, e não guardado na abertura do aplicativo. Antes o IP era lido uma
    /// única vez, no início: quem trocasse de rede — sair do Wi-Fi de casa e entrar no da
    /// escola, ou o roteador renovar o endereço — continuava vendo o número antigo no painel
    /// e passava para a turma um endereço que não levava a lugar nenhum. O servidor sempre
    /// atendeu no endereço novo; era só o painel que mentia.
    public var localIPAddress: String {
        NetworkListenerService.enderecoLocal() ?? "127.0.0.1"
    }

    public var isChatEnabled: Bool {
        get { webSocketHandler.isChatEnabled }
        set { webSocketHandler.isChatEnabled = newValue }
    }


    public weak var chatObserver: ChatObserverProtocol? {
        didSet { webSocketHandler.chatObserver = chatObserver }
    }
    public weak var presenceObserver: StudentPresenceObserverProtocol? {
        didSet { webSocketHandler.presenceObserver = presenceObserver }
    }
    public weak var clientObserver: ClientObserverProtocol? {
        didSet { webSocketHandler.clientObserver = clientObserver }
    }

    public var onFailure: ((String) -> Void)?

    private var listener: NWListener?
    /// Anúncio Bonjour pedido para este servidor, aplicado também quando ele (re)sobe.
    private var anuncio: NWListener.Service?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionsLock = NSLock()

    /// Teto para o cabeçalho HTTP acumulado antes de desistir da conexão.
    private static let maxRequestHeaderBytes = 64 * 1024

    private let staticFileProvider: StaticFileProviderService
    private let streamerService: MJPEGStreamerService
    private let webSocketHandler: WebSocketHandlerService
    private let downloads = FileDownloadService()

    public init(port: UInt16 = 8080, webAssetsPath: URL) {
        self.port = port
        self.staticFileProvider = StaticFileProviderService(webAssetsPath: webAssetsPath)
        self.streamerService = MJPEGStreamerService()
        self.webSocketHandler = WebSocketHandlerService()
    }

    public func start() throws {
        // Subir um segundo listener na mesma porta não substitui o primeiro: quem falha ao
        // ligar é o socket, de forma assíncrona, e não esta chamada — então o erro não
        // chegava a lugar nenhum e o servidor saía do ar em silêncio.
        //
        // O caminho real é este: a captura cai sozinha, o servidor segue no ar de propósito
        // (para a turma receber o aviso) e o professor clica em "Iniciar Transmissão" de novo.
        guard !isRunning else { return }

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        // Sem isto, uma falha ao ligar na porta (outro aplicativo já usando a 8080) deixava
        // o painel anunciando "TRANSMITINDO AO VIVO" com o servidor morto.
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let erro) = state else { return }
            print("[NetworkListener] Servidor falhou na porta \(self?.port ?? 0): \(erro)")
            guard let self else { return }
            self.isRunning = false
            // Só baixar a flag não bastava: ninguém a lia, e o painel seguia "AO VIVO" com
            // o servidor morto. Quem cuida da tela precisa ser avisado.
            let mensagem: String
            if case .posix(let codigo) = erro, codigo == .EADDRINUSE {
                mensagem = "A porta \(self.port) já está em uso por outro aplicativo. "
                    + "Feche-o e inicie a transmissão de novo."
            } else {
                mensagem = "O servidor da aula parou de funcionar (\(erro.localizedDescription))."
            }
            self.onFailure?(mensagem)
        }

        listener.service = anuncio
        // Um nome repetido na rede (dois professores com o AulaCast na mesma sala) não
        // derruba nada: o sistema renomeia o anúncio, e só isso é registrado.
        listener.serviceRegistrationUpdateHandler = { mudanca in
            if case .add(let endpoint) = mudanca {
                print("[Bonjour] Anunciado como \(endpoint)")
            }
        }

        self.listener = listener
        listener.start(queue: .global(qos: .userInteractive))
        self.isRunning = true
    }

    public func definirAnuncio(_ servico: NWListener.Service?) {
        anuncio = servico
        listener?.service = servico
    }

    public func stop() {
        self.listener?.cancel()
        self.listener = nil

        connectionsLock.lock()
        self.connections.values.forEach { $0.cancel() }
        self.connections.removeAll()
        connectionsLock.unlock()

        // Sessão nova começa sem o quadro nem o estado da anterior: senão quem abrisse a
        // página na próxima aula veria por um instante a última tela da aula passada.
        streamerService.reset()
        webSocketHandler.reset()

        self.isRunning = false
    }

    /// Quantos alunos estão com o vídeo aberto agora (conexões de `/stream` vivas).
    public var activeStreamCount: Int { streamerService.activeStreamCount }

    public func broadcastFrame(_ jpegData: Data) {
        streamerService.updateFrame(jpegData)
    }

    public func broadcastChatMessage(_ message: ChatMessage) {
        webSocketHandler.broadcastChatMessage(message)
    }

    public func broadcastControlMessage(type: String, payload: [String: String]? = nil) {
        webSocketHandler.broadcastControlMessage(type: type, payload: payload)
    }

    public func updateSharedFiles(_ files: [SharedFile]) {
        downloads.atualizar(files)
        webSocketHandler.anunciarArquivos(files)
    }

    private func handleConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)

        connectionsLock.lock()
        connections[id] = connection
        connectionsLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connectionsLock.lock()
                self?.connections.removeValue(forKey: id)
                self?.connectionsLock.unlock()
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInteractive))

        receiveRequest(connection: connection, acumulado: Data())
    }

    /// Lê a requisição HTTP até o fim dos cabeçalhos antes de decidir o que fazer com ela.
    ///
    /// O TCP não respeita fronteira de mensagem: numa rede de escola é comum a requisição
    /// chegar partida em duas leituras. Decidir na primeira leitura fazia um handshake de
    /// WebSocket partido no meio não ser reconhecido como tal (o cabeçalho `Upgrade` ainda
    /// não tinha chegado) e cair no servidor de arquivos, devolvendo 404 ao aluno.
    private func receiveRequest(connection: NWConnection, acumulado: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            guard error == nil else {
                connection.cancel()
                return
            }

            var buffer = acumulado
            if let data = data, !data.isEmpty {
                buffer.append(data)
            }

            // Cabeçalho maior que isto não é requisição de navegador, é erro ou abuso.
            guard buffer.count <= Self.maxRequestHeaderBytes else {
                print("[HTTP] Cabeçalho grande demais (\(buffer.count) bytes); conexão encerrada.")
                connection.cancel()
                return
            }

            guard let fimDosCabecalhos = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    // O cliente fechou antes de terminar a requisição: não há o que servir.
                    connection.cancel()
                    return
                }
                self.receiveRequest(connection: connection, acumulado: buffer)
                return
            }

            let cabecalhos = buffer[buffer.startIndex..<fimDosCabecalhos.upperBound]
            let req = String(data: cabecalhos, encoding: .utf8) ?? ""
            let (metodo, caminho) = Self.linhaDeRequisicao(req)

            // Decide pela linha de requisição e pelo cabeçalho de verdade. Antes a busca era
            // por trecho em qualquer lugar do texto: `GET /stream-ajuda.html` recebia o vídeo
            // em vez do arquivo.
            if Self.pedeWebSocket(req) {
                let handled = self.webSocketHandler.handleHandshake(connection: connection, request: req)
                if !handled {
                    print("[WebSocket Warning] Requisicao /ws nao concluiu handshake.")
                }
            } else if metodo == "GET" && caminho == "/stream" {
                self.streamerService.serveStream(connection: connection)
            } else if metodo == "GET" && caminho.hasPrefix(FileDownloadService.prefixoDaRota) {
                self.downloads.serve(connection: connection, caminho: caminho)
            } else {
                self.staticFileProvider.serve(connection: connection, request: req)
            }
        }
    }

    /// Método e caminho (sem a query string) da primeira linha da requisição.
    public static func linhaDeRequisicao(_ req: String) -> (metodo: String, caminho: String) {
        let primeira = req.prefix { $0 != "\r" && $0 != "\n" }
        let partes = primeira.split(separator: " ", omittingEmptySubsequences: true)
        guard partes.count >= 2 else { return ("", "") }
        let alvo = partes[1]
        let caminho = alvo.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return (String(partes[0]).uppercased(), String(caminho))
    }

    /// Verdadeiro se algum cabeçalho `Upgrade` pede websocket.
    public static func pedeWebSocket(_ req: String) -> Bool {
        req.components(separatedBy: "\r\n").dropFirst().contains { linha in
            let partes = linha.split(separator: ":", maxSplits: 1)
            guard partes.count == 2 else { return false }
            return partes[0].trimmingCharacters(in: .whitespaces).lowercased() == "upgrade"
                && partes[1].lowercased().contains("websocket")
        }
    }

    /// Uma interface de rede ativa com endereço IPv4.
    public struct InterfaceDeRede: Equatable {
        public let nome: String
        public let ip: String

        public init(nome: String, ip: String) {
            self.nome = nome
            self.ip = ip
        }
    }

    public static func getWiFiAddress() -> String? { enderecoLocal() }

    /// Endereço que a turma digita no navegador, relido a cada consulta.
    public static func enderecoLocal() -> String? {
        melhorEndereco(
            entre: interfacesAtivas(),
            interfaceWiFi: CWWiFiClient.shared().interface()?.interfaceName
        )
    }

    /// Escolhe qual endereço mostrar entre as interfaces ativas.
    ///
    /// Antes só `en0` e `en1` eram consideradas. Um cabo de rede ou um adaptador USB-C
    /// aparece como `en2` ou acima, e nesses casos o painel mostrava `127.0.0.1` — um
    /// endereço que não leva aluno nenhum a lugar nenhum.
    ///
    /// O Wi-Fi vem primeiro porque é assim que a turma entra na prática, e quem diz qual
    /// interface é o Wi-Fi é o próprio sistema (CoreWLAN), em vez de um palpite pelo nome:
    /// nem todo Mac chama o Wi-Fi de `en0`. Túneis de VPN (`utun`), AirDrop (`awdl`, `llw`)
    /// e o Wi-Fi de compartilhamento (`ap1`) ficam de fora — têm IP, mas não é por eles que
    /// a turma chega.
    public static func melhorEndereco(
        entre candidatos: [InterfaceDeRede],
        interfaceWiFi: String? = nil
    ) -> String? {
        let uteis = candidatos.filter { candidato in
            let nome = candidato.nome
            guard !nome.hasPrefix("utun"), !nome.hasPrefix("awdl"), !nome.hasPrefix("llw"),
                  !nome.hasPrefix("bridge"), nome != "ap1", nome != "lo0" else {
                return false
            }
            // 169.254.x.x é o endereço que o macOS inventa quando não conseguiu falar com o
            // roteador. Mostrá-lo é pior que não mostrar nada: tem cara de endereço bom.
            return !candidato.ip.hasPrefix("169.254.") && !candidato.ip.isEmpty
        }

        func prioridade(_ interface: InterfaceDeRede) -> Int {
            if let wifi = interfaceWiFi, interface.nome == wifi { return 0 }
            if interface.nome == "en0" { return 1 }
            if interface.nome == "en1" { return 2 }
            return interface.nome.hasPrefix("en") ? 3 : 4
        }

        return uteis.min { esquerda, direita in
            let (pe, pd) = (prioridade(esquerda), prioridade(direita))
            // Empate resolvido pelo nome, para a escolha não mudar sozinha entre execuções.
            return pe == pd ? esquerda.nome < direita.nome : pe < pd
        }?.ip
    }

    /// Varre as interfaces do sistema em busca das que estão no ar com IPv4.
    public static func interfacesAtivas() -> [InterfaceDeRede] {
        var encontradas: [InterfaceDeRede] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let primeira = ifaddr else { return [] }

        for ptr in sequence(first: primeira, next: { $0.pointee.ifa_next }) {
            guard let enderecoBruto = ptr.pointee.ifa_addr else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            let endereco = enderecoBruto.pointee

            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  endereco.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                enderecoBruto,
                socklen_t(endereco.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                socklen_t(0),
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            encontradas.append(
                InterfaceDeRede(nome: String(cString: ptr.pointee.ifa_name), ip: String(cString: hostname))
            )
        }

        freeifaddrs(ifaddr)
        return encontradas
    }
}