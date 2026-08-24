import Foundation

/// Interface segregada para observadores de mensagens de chat (ISP).
public protocol ChatObserverProtocol: AnyObject {
    func didReceiveChatMessage(_ message: ChatMessage)
}

/// Interface segregada para observadores de solicitações de dúvida (ISP).
/// Identifica o aluno pela conexão (`clientId`), e não pelo nome digitado: o mesmo aluno
/// pode trocar de nome no meio da aula, e isso não pode criar um segundo registro.
public protocol HandRaiseObserverProtocol: AnyObject {
    func didToggleHandRaise(clientId: String, displayName: String, isRaised: Bool)
}

/// Interface segregada para observadores de conexões de clientes (ISP).
public protocol ClientObserverProtocol: AnyObject {
    func didClientConnect(_ client: ConnectedClient)
    func didClientDisconnect(clientId: String)
}

/// Interface segregada para identificação do aluno e presença na tela (ISP).
public protocol StudentPresenceObserverProtocol: AnyObject {
    /// O aluno informou nome e matrícula na entrada.
    func didIdentifyStudent(clientId: String, name: String, matricula: String)
    /// A aba do aluno passou a estar (ou deixou de estar) visível na tela dele.
    func didChangeWatching(clientId: String, isWatching: Bool)
}

/// Interface segregada para avisar que a captura parou sem ninguém ter pedido —
/// monitor desconectado, permissão revogada, erro do sistema (ISP).
/// Isolada na MainActor porque encerra a sessão e atualiza a interface.
@MainActor
public protocol CaptureLifecycleObserverProtocol: AnyObject {
    func captureDidStopUnexpectedly(reason: String)
}