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

    public var professorName: String {
        get { webSocketHandler.professorName }
        set { webSocketHandler.professorName = newValue }
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
        let parameters = NWParameters.tcp
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        self.listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        self.listener?.start(queue: .global(qos: .userInteractive))
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

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, !data.isEmpty else { return }
            let req = String(data: data, encoding: .utf8) ?? ""
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