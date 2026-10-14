import Foundation
import dnssd

/// Registra `aulacast.local` como hostname mDNS enquanto a transmissão está no ar.
///
/// O macOS resolve `.local` via Multicast DNS (RFC 6762). A API `dnssd` permite registrar
/// um A record adicional para qualquer nome `.local` — o mesmo mecanismo que faz
/// `<nome-do-mac>.local` funcionar em toda rede local moderna.
///
/// Compatível com Chrome/Edge (Windows, Android, macOS), Safari (iOS/macOS) e
/// qualquer sistema com suporte a mDNS (avahi no Linux). O Firefox desabilita mDNS
/// por padrão, mas a turma pode continuar usando o IP numérico como fallback.
///
/// ## Duas transmissões na mesma rede
/// O registro é único (`kDNSServiceFlagsUnique`). O sistema NÃO renomeia um A record em
/// conflito: ele avisa pelo callback com `kDNSServiceErr_NameConflict`. Por isso o serviço
/// escuta esse callback e tenta `aulacast-2.local`, `aulacast-3.local` e assim por diante,
/// sozinho. A porta não entra nessa conta: cada Mac tem o próprio IP, e a 8080 de um não
/// colide com a do outro.
///
/// O nome só é divulgado (`onHostnameChange`) depois que o sistema o **confirma**, o que
/// leva cerca de um segundo (sondagem do mDNS), e é retirado (`nil`) no instante em que se
/// perde. Sem nome confirmado, quem mostra o endereço deve cair no IP, que nunca é ambíguo.
public final class MDNSHostnameService: HostnameAdvertisingProtocol {
    /// Nome-base do primeiro candidato (`aulacast.local`).
    public static let baseLabel = "aulacast"
    /// Quantos nomes tentar antes de desistir e deixar só o IP.
    public static let maxAttempts = 20

    /// Nome canônico (com ponto final) da tentativa `attempt`, a partir de 1:
    /// `aulacast.local.`, `aulacast-2.local.`, `aulacast-3.local.` …
    public static func hostname(attempt: Int) -> String {
        attempt <= 1 ? "\(baseLabel).local." : "\(baseLabel)-\(attempt).local."
    }

    /// O que fazer com a resposta do sistema a um registro.
    public enum PassoDoRegistro: Equatable {
        /// O nome é nosso: pode ser divulgado.
        case confirmar
        /// Conflito: tentar o nome da tentativa indicada.
        case tentarCom(tentativa: Int)
        /// Conflito e nenhum nome livre dentro de `maxAttempts`.
        case desistir
        /// Qualquer outro erro: sem nome; só o IP vale.
        case falhar
    }

    /// Decide o próximo passo a partir do erro devolvido pelo sistema na `tentativa` atual.
    public static func proximoPasso(erro: DNSServiceErrorType, tentativa: Int) -> PassoDoRegistro {
        switch erro {
        case DNSServiceErrorType(kDNSServiceErr_NoError):
            return .confirmar
        case DNSServiceErrorType(kDNSServiceErr_NameConflict):
            return tentativa < maxAttempts ? .tentarCom(tentativa: tentativa + 1) : .desistir
        default:
            return .falhar
        }
    }

    /// Chamado na fila principal com o nome confirmado, sem o ponto final
    /// (`aulacast-2.local`), ou `nil` quando o registro é desfeito, perdido ou desiste.
    /// Atribua antes de `start`: o serviço o lê de outra fila.
    public var onHostnameChange: ((String?) -> Void)?

    /// Nome em uso na tentativa atual, com ponto final. Só é tocado na `queue`.
    private var hostname: String
    private var ip: String?
    private var attempt = 1
    private var connectionRef: DNSServiceRef?
    private var recordRef: DNSRecordRef?
    private var dispatchSource: DispatchSourceRead?
    /// Todo o estado acima é tocado só nesta fila, inclusive pelo callback do `dnssd`.
    private let queue = DispatchQueue(label: "br.com.ifpi.aulacast.mdns-hostname")

    public init() {
        self.hostname = Self.hostname(attempt: 1)
    }

    /// Registra o hostname apontando para `ip`. Sem efeito se já estiver ativo.
    /// IP de loopback não é registrado: um nome que só funciona neste Mac não serve à turma.
    public func start(ip: String) {
        queue.sync {
            guard connectionRef == nil else { return }
            guard !ip.hasPrefix("127.") else {
                print("[mDNS] Sem rede (IP \(ip)); o nome não será registrado")
                notify(nil)
                return
            }
            self.ip = ip
            attempt = 1
            register()
        }
    }

    /// Remove o registro e libera os recursos. Sem efeito se já estiver parado.
    public func stop() {
        queue.sync {
            guard dispatchSource != nil else { return }
            teardown()
            print("[mDNS] \(hostname.dropLast()) removido")
            notify(nil)
        }
    }

    deinit {
        // Sem `queue.sync`: se a última referência cair dentro de um callback, o `deinit` roda
        // na própria fila e um `sync` nela aborta o app. `cancel()` é seguro de qualquer fila.
        dispatchSource?.cancel()
    }

    // MARK: - Registro

    /// Liga o callback em C ao serviço sem prendê-lo: o callback só enxerga esta ponte, que
    /// guarda o serviço por referência fraca. Se o serviço já foi liberado, o aviso se perde.
    private final class Ponte {
        weak var servico: MDNSHostnameService?
        init(_ servico: MDNSHostnameService) { self.servico = servico }
    }

    /// Registra a tentativa atual. Sempre chamado na `queue`.
    private func register() {
        guard let ip else { return }

        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else {
            print("[mDNS] IP inválido para registro: \(ip)")
            notify(nil)
            return
        }

        var connRef: DNSServiceRef?
        let errConn = DNSServiceCreateConnection(&connRef)
        guard errConn == kDNSServiceErr_NoError, let conn = connRef else {
            print("[mDNS] Falha ao criar conexão dnssd: \(errConn)")
            notify(nil)
            return
        }

        hostname = Self.hostname(attempt: attempt)
        let ponte = Ponte(self)
        // +1 manual, devolvido no cancel handler: a ponte vive enquanto o callback puder ser chamado.
        let context = Unmanaged.passRetained(ponte).toOpaque()
        var recRef: DNSRecordRef?
        let errReg = withUnsafeBytes(of: addr.s_addr) { ptr -> DNSServiceErrorType in
            DNSServiceRegisterRecord(
                conn,
                &recRef,
                DNSServiceFlags(kDNSServiceFlagsUnique),
                0,                                        // todas as interfaces
                hostname,
                UInt16(kDNSServiceType_A),
                UInt16(kDNSServiceClass_IN),
                UInt16(MemoryLayout<UInt32>.size),        // 4 bytes — IPv4
                ptr.baseAddress,
                0,                                        // TTL gerenciado pelo sistema
                { _, _, _, errorCode, context in
                    // Ponteiro de função C: não captura nada, só recebe o `context`.
                    guard let context else { return }
                    let ponte = Unmanaged<Ponte>.fromOpaque(context).takeUnretainedValue()
                    ponte.servico?.registroRespondeu(errorCode)
                },
                context
            )
        }

        guard errReg == kDNSServiceErr_NoError else {
            print("[mDNS] Falha ao registrar \(hostname): \(errReg)")
            Unmanaged<Ponte>.fromOpaque(context).release()
            DNSServiceRefDeallocate(conn)
            notify(nil)
            return
        }

        // Processa os eventos da API na própria fila do serviço via DispatchSource.
        // Sem isto, `DNSServiceProcessResult` nunca é chamado e o registro fica pendente.
        let fd = DNSServiceRefSockFD(conn)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            // Erro aqui (o mDNSResponder caiu ou reiniciou) deixa o socket em EOF, e o handler
            // dispararia sem parar: encerrar o registro em vez de girar a 100% de um núcleo.
            if DNSServiceProcessResult(conn) != kDNSServiceErr_NoError {
                ponte.servico?.conexaoPerdida()
            }
        }
        source.setCancelHandler {
            DNSServiceRefDeallocate(conn)
            Unmanaged<Ponte>.fromOpaque(context).release()
        }
        source.resume()

        connectionRef = conn
        recordRef = recRef
        dispatchSource = source

        print("[mDNS] \(hostname.dropLast()) solicitado → \(ip)")
    }

    /// Resposta do sistema ao registro. Roda na `queue`, porque é ela que processa o socket.
    /// Pode chegar também depois de o nome já estar confirmado (conflito tardio: volta do
    /// sono, duas redes que se juntam, outro Mac que sonda o mesmo nome).
    private func registroRespondeu(_ erro: DNSServiceErrorType) {
        switch Self.proximoPasso(erro: erro, tentativa: attempt) {
        case .confirmar:
            print("[mDNS] \(hostname.dropLast()) confirmado")
            notify(String(hostname.dropLast()))
        case .tentarCom(let proxima):
            print("[mDNS] \(hostname.dropLast()) já está em uso na rede; tentando outro nome")
            // Retirar o nome já: se ele estava confirmado e na tela, deixou de ser nosso.
            notify(nil)
            teardown()
            attempt = proxima
            register()
        case .desistir:
            print("[mDNS] Nenhum nome livre em \(Self.maxAttempts) tentativas; só o IP vale")
            notify(nil)
            teardown()
        case .falhar:
            print("[mDNS] Falha no registro de \(hostname.dropLast()): \(erro)")
            notify(nil)
            teardown()
        }
    }

    /// A conexão com o mDNSResponder se perdeu. Roda na `queue`.
    private func conexaoPerdida() {
        guard dispatchSource != nil else { return }
        print("[mDNS] Conexão com o mDNSResponder perdida; o nome \(hostname.dropLast()) deixou de valer")
        teardown()
        notify(nil)
    }

    /// Cancela o registro atual. Sempre chamado na `queue`.
    private func teardown() {
        dispatchSource?.cancel()
        dispatchSource = nil
        connectionRef = nil
        recordRef = nil
    }

    private func notify(_ nome: String?) {
        let aviso = onHostnameChange
        DispatchQueue.main.async { aviso?(nome) }
    }
}
