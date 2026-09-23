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
/// O registro é único (`kDNSServiceFlagsUnique`): se dois Macs tentarem usar o mesmo
/// nome, o sistema renomeia o segundo para `aulacast-2.local`, igual ao que já
/// acontece com o Bonjour do serviço HTTP.
public final class MDNSHostnameService {
    /// Nome anunciado na rede. Precisa terminar com ponto (forma canônica DNS).
    public let hostname: String

    private var connectionRef: DNSServiceRef?
    private var recordRef: DNSRecordRef?
    private var dispatchSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "br.com.ifpi.aulacast.mdns-hostname")

    public init(hostname: String = "aulacast.local.") {
        self.hostname = hostname
    }

    /// Registra o hostname apontando para `ip`. Sem efeito se já estiver ativo.
    public func start(ip: String) {
        guard connectionRef == nil else { return }

        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else {
            print("[mDNS] IP inválido para registro: \(ip)")
            return
        }

        var connRef: DNSServiceRef?
        let errConn = DNSServiceCreateConnection(&connRef)
        guard errConn == kDNSServiceErr_NoError, let conn = connRef else {
            print("[mDNS] Falha ao criar conexão dnssd: \(errConn)")
            return
        }

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
                { _, _, _, _, _ in },                     // callback de confirmação (ignorado)
                nil
            )
        }

        guard errReg == kDNSServiceErr_NoError else {
            print("[mDNS] Falha ao registrar \(hostname): \(errReg)")
            DNSServiceRefDeallocate(conn)
            return
        }

        // Processa os eventos da API em uma fila dedicada via DispatchSource.
        // Sem isto, `DNSServiceProcessResult` nunca é chamado e o registro fica pendente.
        let fd = DNSServiceRefSockFD(conn)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { DNSServiceProcessResult(conn) }
        source.setCancelHandler {
            DNSServiceRefDeallocate(conn)
        }
        source.resume()

        connectionRef = conn
        recordRef = recRef
        dispatchSource = source

        print("[mDNS] \(hostname.dropLast()) registrado → \(ip)")
    }

    /// Remove o registro e libera os recursos. Sem efeito se já estiver parado.
    public func stop() {
        guard dispatchSource != nil else { return }
        dispatchSource?.cancel()
        dispatchSource = nil
        connectionRef = nil
        recordRef = nil
        print("[mDNS] \(hostname.dropLast()) removido")
    }

    deinit { stop() }
}
