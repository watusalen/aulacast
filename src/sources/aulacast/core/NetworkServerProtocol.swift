import Foundation
import Network

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
    /// Troca a lista de arquivos que a turma pode baixar e avisa quem está conectado.
    func updateSharedFiles(_ files: [SharedFile])
    /// Avisado quando um download de arquivo compartilhado começa ou termina.
    var onFileDownloadUpdate: ((FileDownloadStats) -> Void)? { get set }
}

/// Servidor capaz de anunciar a si mesmo via Bonjour, na própria porta.
public protocol BonjourHostProtocol: AnyObject {
    /// Liga (ou, com `nil`, desliga) o anúncio. Vale também para o servidor ainda parado:
    /// o anúncio sobe junto com ele.
    func definirAnuncio(_ servico: NWListener.Service?)
}

/// Abstração para registradores de serviço Bonjour/mDNS (DIP).
public protocol ServiceAdvertiserProtocol: AnyObject {
    func startAdvertising()
    func stopAdvertising()
}