import Foundation

/// Interface segregada para observadores de mensagens de chat (ISP).
public protocol ChatObserverProtocol: AnyObject {
    func didReceiveChatMessage(_ message: ChatMessage)
}

/// Interface segregada para observadores da mão levantada (ISP).
/// Identifica o aluno pela conexão (`clientId`), e não pelo nome digitado: o mesmo aluno
/// pode trocar de nome no meio da aula, e isso não pode criar um segundo registro.
/// O `displayName` é sempre o nome aceito no IDENTIFY, nunca o que a mensagem trouxer.
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
    /// O aluno informou o nome na entrada.
    func didIdentifyStudent(clientId: String, name: String)
    /// A aba do aluno passou a estar (ou deixou de estar) visível na tela dele.
    func didChangeWatching(clientId: String, isWatching: Bool)
}

/// Interface segregada para avisar que a captura parou sem ninguém ter pedido —
/// monitor desconectado, permissão revogada, erro do sistema (ISP).
/// Isolada na MainActor porque encerra a sessão e atualiza a interface.
@MainActor
public protocol CaptureLifecycleObserverProtocol: AnyObject {
    func captureDidStopUnexpectedly(reason: String)
    /// Algo deu errado com a captura ainda de pé (troca de fonte ou de qualidade que não
    /// pegou): a turma segue vendo o que via antes, e o professor precisa saber.
    func captureDidReportError(_ message: String)
    /// A janela transmitida sumiu (fechada ou minimizada) sem o ScreenCaptureKit reclamar:
    /// os quadros simplesmente param de chegar.
    func captureSourceDidDisappear(sourceName: String)
    /// Há de novo o que transmitir: a janela voltou ou o professor escolheu outra fonte.
    func captureSourceIsAvailableAgain()
}

public extension CaptureLifecycleObserverProtocol {
    func captureDidReportError(_ message: String) {}
    func captureSourceDidDisappear(sourceName: String) {}
    func captureSourceIsAvailableAgain() {}
}