import Foundation
import Network

/// Servico central de escuta de rede e orquestracao HTTP/WebSocket (SRP, DIP, LSP).
public final class NetworkListenerService: NetworkServerProtocol {
    public private(set) var isRunning: Bool = false
    public let port: UInt16
    public private(set) var localIPAddress: String

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
    public weak var handRaiseObserver: HandRaiseObserverProtocol? {
        didSet { webSocketHandler.handRaiseObserver = handRaiseObserver }
    }
    public weak var clientObserver: ClientObserverProtocol? {
        didSet { webSocketHandler.clientObserver = clientObserver }
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionsLock = NSLock()

    /// Teto para o cabeçalho HTTP acumulado antes de desistir da conexão.
    private static let maxRequestHeaderBytes = 64 * 1024

    private let staticFileProvider: StaticFileProviderService
    private let streamerService: MJPEGStreamerService
    private let webSocketHandler: WebSocketHandlerService

    public init(port: UInt16 = 8080, webAssetsPath: URL) {
        self.port = port
        self.staticFileProvider = StaticFileProviderService(webAssetsPath: webAssetsPath)
        self.streamerService = MJPEGStreamerService()
        self.webSocketHandler = WebSocketHandlerService()
        self.localIPAddress = NetworkListenerService.getWiFiAddress() ?? "127.0.0.1"
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
            self?.isRunning = false
        }

        self.listener = listener
        listener.start(queue: .global(qos: .userInteractive))
        self.isRunning = true
    }

    public func stop() {
        self.listener?.cancel()
        self.listener = nil

        connectionsLock.lock()
        self.connections.values.forEach { $0.cancel() }
        self.connections.removeAll()
        connectionsLock.unlock()

        self.isRunning = false
    }

    public func broadcastFrame(_ jpegData: Data) {
        streamerService.updateFrame(jpegData)
    }

    public func broadcastChatMessage(_ message: ChatMessage) {
        webSocketHandler.broadcastChatMessage(message)
    }

    public func broadcastControlMessage(type: String, payload: [String: String]? = nil) {
        webSocketHandler.broadcastControlMessage(type: type, payload: payload)
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
            let reqLower = req.lowercased()

            if reqLower.contains("upgrade: websocket") {
                let handled = self.webSocketHandler.handleHandshake(connection: connection, request: req)
                if !handled {
                    print("[WebSocket Warning] Requisicao /ws nao concluiu handshake.")
                }
            } else if reqLower.contains("get /stream") {
                self.streamerService.serveStream(connection: connection)
            } else {
                self.staticFileProvider.serve(connection: connection, request: req)
            }
        }
    }

    public static func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            if (flags & (IFF_UP | IFF_RUNNING)) != 0 && addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}