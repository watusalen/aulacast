import Foundation
import Network

/// Abstração para servidores de rede e transmissão (DIP).
public protocol NetworkServerProtocol: AnyObject {
    var isRunning: Bool { get }
    var port: UInt16 { get }
    var localIPAddress: String { get }
    var isChatEnabled: Bool { get set }
    /// Desligado por padrão: mensagem de aluno continua privada com o professor. Ligado,
    /// `broadcastChatMessage` também manda a mensagem do aluno para toda a turma.
    var isStudentChatVisibleToClass: Bool { get set }

    var chatObserver: ChatObserverProtocol? { get set }
    var presenceObserver: StudentPresenceObserverProtocol? { get set }
    var handRaiseObserver: HandRaiseObserverProtocol? { get set }
    var clientObserver: ClientObserverProtocol? { get set }

    /// Chamado quando o servidor cai depois de `start()` ter voltado sem erro (a porta já
    /// estava em uso, por exemplo: essa falha só chega de forma assíncrona).
    var onFailure: ((String) -> Void)? { get set }

    func start() throws
    func stop()
    func broadcastFrame(_ jpegData: Data)
    /// Encaminha um fragmento fMP4 (H.264) para a rota `/stream.mp4` — ver `MP4StreamerService`.
    func broadcastVideoFragment(_ data: Data, isInitSegment: Bool, isKeyFrame: Bool)
    func broadcastChatMessage(_ message: ChatMessage)
    func broadcastControlMessage(type: String, payload: [String: String]?)
    /// Troca a lista de arquivos que a turma pode baixar e avisa quem está conectado.
    func updateSharedFiles(_ files: [SharedFile])
    /// O professor abaixou a mão de um aluno: avisa só aquele aluno (`HAND_LOWERED`).
    func lowerHand(clientId: String)
    /// Fixa (ou, com `nil`, desafixa) a mensagem do topo do chat da turma e avisa quem está
    /// conectado (`CHAT_PINNED`). Quem entrar depois a recebe no `CONNECTED`.
    func updatePinnedMessage(_ text: String?)
    /// Avisado quando um download de arquivo compartilhado começa ou termina.
    var onFileDownloadUpdate: ((FileDownloadStats) -> Void)? { get set }
    /// Um aluno novo abriu `/stream.mp4` (ou uma conexão precisou re-sincronizar): quem
    /// codifica H.264 deve forçar um quadro-chave no próximo quadro, para ele não ficar sem
    /// imagem até o próximo quadro-chave "de rotina".
    var onVideoViewerNeedsKeyFrame: (() -> Void)? { get set }
    /// Só depuração (arquivo de métricas): define o que o `inicio` da sessão traz da captura
    /// (resolução, fps, fonte...) e de onde tirar os tempos por aluno para o `fim`. Chamar antes de `start()`.
    func configurarSessaoDeMetricas(contexto: [String: Any], tempos: (() -> [String: [String: Any]])?, configuracao: (() -> ConfigDeCaptura)?)
    /// Só depuração: escreve uma linha de evento no arquivo de métricas (sem efeito se desligado).
    func registrarEventoDeSessao(_ tipo: String, _ dados: [String: Any])
}

public extension NetworkServerProtocol {
    func configurarSessaoDeMetricas(contexto: [String: Any], tempos: (() -> [String: [String: Any]])?, configuracao: (() -> ConfigDeCaptura)?) {}
    func registrarEventoDeSessao(_ tipo: String, _ dados: [String: Any]) {}
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