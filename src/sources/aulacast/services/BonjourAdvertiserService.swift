import Foundation
import Network

/// Servico responsavel exclusivamente pelo anuncio de rede via Bonjour/mDNS (SRP, DIP, LSP).
/// Utiliza NWListener com porta 0 (efemera) para evitar conflito com o listener principal na porta 8080.
/// O servico Bonjour anuncia metadados TXT com a porta real do servidor.
public final class BonjourAdvertiserService: ServiceAdvertiserProtocol {
    private var listener: NWListener?
    private let serverPort: UInt16
    private let serviceName: String

    public init(port: UInt16 = 8080, serviceName: String = "AulaCast - IFPI") {
        self.serverPort = port
        self.serviceName = serviceName
    }

    public func startAdvertising() {
        // Anunciar duas vezes (o professor reinicia a transmissão) trocava o listener sem
        // cancelar o anterior: sobravam dois anúncios do mesmo serviço na rede e um
        // listener pendurado até o app fechar.
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            // Porta 0 = porta efemera atribuida pelo SO, evita "Address already in use"
            self.listener = try NWListener(using: parameters)
            self.listener?.service = NWListener.Service(
                name: serviceName,
                type: "_aulacast._tcp",
                txtRecord: NWTXTRecord(["port": "\(serverPort)"])
            )
            self.listener?.start(queue: .global(qos: .utility))
        } catch {
            print("[BonjourService] Erro ao iniciar anuncio: \(error)")
        }
    }

    public func stopAdvertising() {
        self.listener?.cancel()
        self.listener = nil
    }
}