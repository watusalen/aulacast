import Foundation

/// Abstração para servidores de rede e transmissão (DIP).
public protocol NetworkServerProtocol: AnyObject {
    var isRunning: Bool { get }
    var port: UInt16 { get }
    var localIPAddress: String { get }
    var isChatEnabled: Bool { get set }

    var chatObserver: ChatObserverProtocol? { get set }
    var presenceObserver: StudentPresenceObserverProtocol? { get set }
    var clientObserver: ClientObserverProtocol? { get set }

    /// Chamado quando o servidor cai depois de `start()` ter voltado sem erro (a porta já
    /// estava em uso, por exemplo: essa falha só chega de forma assíncrona).
    var onFailure: ((String) -> Void)? { get set }

    func start() throws
    func stop()
    func broadcastFrame(_ jpegData: Data)
    func broadcastChatMessage(_ message: ChatMessage)
    func broadcastControlMessage(type: String, payload: [String: String]?)
}

/// Abstração para registradores de serviço Bonjour/mDNS (DIP).
public protocol ServiceAdvertiserProtocol: AnyObject {
    func startAdvertising()
    func stopAdvertising()
}