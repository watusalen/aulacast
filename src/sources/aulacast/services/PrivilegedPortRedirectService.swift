import Foundation

/// Redireciona a porta 80 (privilegiada) para a porta real do servidor via `pf`, para a
/// turma digitar só `aulacast.local`, sem porta.
///
/// A porta 80 só pode ser aberta por root — nenhum app comum consegue escutar nela
/// direto. Em vez de instalar um daemon privilegiado (`SMJobBless`, `launchd`, assinatura
/// própria — infraestrutura grande para um app de sala de aula), pedimos a senha de admin
/// uma vez por transmissão via `osascript ... with administrator privileges` (o mesmo
/// diálogo nativo do Touch ID/senha que qualquer instalador do macOS usa) e usamos esse
/// instante de privilégio só para carregar uma regra de redirecionamento (`rdr`) numa
/// âncora `pf` própria (`aulacastAnchor`). O processo do AulaCast continua rodando sem
/// privilégio nenhum depois disso — quem processa a porta 80 é o kernel, não o app.
///
/// A âncora é exclusiva do AulaCast: ao parar, só ela é esvaziada (`pfctl -a <âncora> -F
/// all`). Não desligamos o `pf` do sistema nem mexemos no `pf.conf` — se a professora já
/// usa VPN ou outro firewall baseado em `pf`, isso continua do jeito que estava. Pedir a
/// senha a cada transmissão (em vez de instalar algo que funciona para sempre) é
/// intencional: sem instalador nem desinstalador, a regra nunca sobrevive a um "Parar
/// transmissão" ou a fechar o app.
public final class PrivilegedPortRedirectService {
    public enum Status: Equatable {
        case inativo
        case ativo
        case falhou(String)
    }

    /// Âncora própria do AulaCast dentro do `pf` — nunca toca em regras de outro programa.
    private static let aulacastAnchor = "br.com.ifpi.aulacast"

    private let queue = DispatchQueue(label: "br.com.ifpi.aulacast.port-redirect")

    /// `true` do instante em que `start` pede o privilégio até `stop` desfazer a regra (ou
    /// o pedido falhar).
    ///
    /// Sem isto, `start`/`stop` chamados mais de uma vez — dois cliques em "Encerrar",
    /// `stopStream` disparado por dois caminhos diferentes, a professora demorando para
    /// digitar a senha enquanto o app tenta de novo — abriam um diálogo de admin NOVO a
    /// cada chamada, mesmo já tendo um pendente ou a regra já carregada. Cada `osascript`
    /// é um pedido de senha por conta própria; só a primeira chamada de cada lado deve
    /// valer.
    private var emAndamentoOuAtivo = false

    public init() {}

    /// Pede a senha de admin e carrega a regra `porta 80 → 127.0.0.1:targetPort`.
    ///
    /// Roda em background — a chamada volta na hora, o resultado chega pelo `completion`
    /// na fila principal quando a professora responder ao diálogo (ou ele expirar). Uma
    /// segunda chamada enquanto a primeira ainda está em andamento (ou já deu certo) não
    /// abre outro diálogo — só devolve, sem chamar `completion` de novo.
    public func start(targetPort: UInt16, completion: @escaping (Status) -> Void) {
        guard !emAndamentoOuAtivo else { return }
        emAndamentoOuAtivo = true

        let script = """
        #!/bin/sh
        set -e
        echo 'rdr pass proto tcp from any to any port 80 -> 127.0.0.1 port \(targetPort)' | /sbin/pfctl -a \(Self.aulacastAnchor) -f -
        /sbin/pfctl -e 2>/dev/null || true
        """
        runPrivileged(script) { [weak self] result in
            switch result {
            case .success:
                completion(.ativo)
            case .failure(let erro):
                // Falhou: libera para uma próxima tentativa poder pedir a senha de novo.
                self?.emAndamentoOuAtivo = false
                completion(.falhou(erro.mensagem))
            }
        }
    }

    /// Esvazia só a âncora do AulaCast. Sem efeito (e sem novo pedido de senha) se
    /// `start` nunca chegou a rodar nesta transmissão, ou se `stop` já rodou.
    public func stop() {
        guard emAndamentoOuAtivo else { return }
        emAndamentoOuAtivo = false

        let script = "/sbin/pfctl -a \(Self.aulacastAnchor) -F all"
        runPrivileged(script) { _ in }
    }

    private struct ErroDeShell: Error {
        let mensagem: String
    }

    private func runPrivileged(
        _ shellScript: String,
        completion: @escaping (Result<Void, ErroDeShell>) -> Void
    ) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aulacast-pf-\(UUID().uuidString).sh")

        do {
            try shellScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            DispatchQueue.main.async {
                completion(.failure(ErroDeShell(mensagem: "Não deu para preparar o script: \(error.localizedDescription)")))
            }
            return
        }

        queue.async {
            defer { try? FileManager.default.removeItem(at: scriptURL) }

            let appleScriptCommand =
                "do shell script \"/bin/sh \(scriptURL.path.aulacastAppleScriptEscaped)\" with administrator privileges"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScriptCommand]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(())) }
                } else {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let mensagem = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "erro desconhecido"
                    print("[pf] Redirecionamento da porta 80 falhou: \(mensagem)")
                    DispatchQueue.main.async { completion(.failure(ErroDeShell(mensagem: mensagem))) }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(ErroDeShell(mensagem: error.localizedDescription)))
                }
            }
        }
    }
}

private extension String {
    /// Escapa `\` e `"` para embutir um caminho dentro de uma string AppleScript.
    var aulacastAppleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
