import Foundation
import Network

/// Servico responsavel exclusivamente pelo anuncio de rede via Bonjour/mDNS (SRP, DIP, LSP).
///
/// O anúncio sai do próprio servidor da aula, na porta fixa dele (8080). Antes ele saía de
/// um segundo listener, em porta sorteada pelo sistema a cada execução, com a porta de
/// verdade só no registro TXT: quem achava a sala pelo Bonjour recebia a porta sorteada,
/// que recusava conexão, e a porta mudava de aula para aula — o que também atrapalha
/// liberar o AulaCast no firewall da escola.
public final class BonjourAdvertiserService: ServiceAdvertiserProtocol {
    public static let tipoDoServico = "_aulacast._tcp"

    private weak var servidor: BonjourHostProtocol?
    private let serviceName: String

    public init(servidor: BonjourHostProtocol, serviceName: String = "AulaCast - IFPI") {
        self.servidor = servidor
        self.serviceName = serviceName
    }

    public func startAdvertising() {
        servidor?.definirAnuncio(NWListener.Service(name: serviceName, type: Self.tipoDoServico))
    }

    public func stopAdvertising() {
        servidor?.definirAnuncio(nil)
    }
}

/// Para servidores que não sabem se anunciar (os dublês de teste, por exemplo).
public final class SemAnuncioService: ServiceAdvertiserProtocol {
    public init() {}
    public func startAdvertising() {}
    public func stopAdvertising() {}
}
