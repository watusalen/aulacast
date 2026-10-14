import Foundation

/// Quem registra o nome `.local` da aula na rede (hoje, o `MDNSHostnameService`).
///
/// Existe como protocolo para o `MainViewModel` poder ser testado com um dublê: sem ele,
/// qualquer teste da tela registraria nomes mDNS de verdade na rede de quem roda a suíte.
public protocol HostnameAdvertisingProtocol: AnyObject {
    /// Chamado na fila principal com o nome confirmado, sem o ponto final
    /// (`aulacast-2.local`), ou `nil` quando o registro é desfeito ou desiste.
    /// Deve ser atribuído antes de `start`: o serviço o lê de outra fila.
    var onHostnameChange: ((String?) -> Void)? { get set }

    func start(ip: String)
    func stop()
}
