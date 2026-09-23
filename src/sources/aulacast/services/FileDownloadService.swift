import Foundation
import Network

/// Entrega os arquivos compartilhados pelo professor (SRP).
///
/// Qualquer tipo de arquivo: o navegador recebe `application/octet-stream` com
/// `Content-Disposition: attachment`, então baixa em vez de tentar abrir — do PDF ao
/// instalador. O arquivo é lido do disco em pedaços e o próximo pedaço só sai quando o
/// anterior foi entregue: um vídeo de alguns GB não vai inteiro para a memória, e um aluno
/// de rede lenta não faz o app acumular dados à espera dele.
public final class FileDownloadService {
    public static let prefixoDaRota = "/arquivos/"
    static let tamanhoDoPedaco = 256 * 1024

    private var arquivos: [String: SharedFile] = [:]
    private let trava = NSLock()

    public init() {}

    /// Troca a lista inteira do que pode ser baixado.
    public func atualizar(_ lista: [SharedFile]) {
        trava.lock()
        arquivos = Dictionary(uniqueKeysWithValues: lista.map { ($0.id, $0) })
        trava.unlock()
    }

    private func arquivo(_ id: String) -> SharedFile? {
        trava.lock()
        defer { trava.unlock() }
        return arquivos[id]
    }

    /// Atende `GET /arquivos/<id>`.
    public func serve(connection: NWConnection, caminho: String) {
        let id = String(caminho.dropFirst(Self.prefixoDaRota.count))
        guard let arquivo = arquivo(id),
              let leitor = try? FileHandle(forReadingFrom: arquivo.url),
              let atributos = try? FileManager.default.attributesOfItem(atPath: arquivo.url.path),
              let tamanho = (atributos[.size] as? NSNumber)?.int64Value else {
            // Id desconhecido, arquivo removido da lista, ou apagado/movido do disco.
            enviarNaoEncontrado(connection)
            return
        }

        // O tamanho é lido agora, e não na hora de compartilhar: se o professor salvou o
        // arquivo de novo depois, o Content-Length precisa bater com o que vai sair.
        let cabecalho = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(tamanho)\r\n"
            + "Content-Disposition: \(Self.disposicao(para: arquivo.name))\r\n"
            + "Cache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Connection: close\r\n\r\n"

        connection.send(content: Data(cabecalho.utf8), completion: .contentProcessed({ [weak self] erro in
            guard erro == nil else {
                try? leitor.close()
                connection.cancel()
                return
            }
            self?.enviarPedaco(de: leitor, por: connection)
        }))
    }

    private func enviarPedaco(de leitor: FileHandle, por connection: NWConnection) {
        let pedaco: Data
        do {
            pedaco = try leitor.read(upToCount: Self.tamanhoDoPedaco) ?? Data()
        } catch {
            try? leitor.close()
            connection.cancel()
            return
        }

        guard !pedaco.isEmpty else {
            // Fim do arquivo: fecha a escrita e deixa o navegador concluir o download.
            try? leitor.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed({ _ in connection.cancel() }))
            return
        }

        connection.send(content: pedaco, completion: .contentProcessed({ [weak self] erro in
            guard erro == nil else {
                // O aluno cancelou o download ou saiu da rede.
                try? leitor.close()
                connection.cancel()
                return
            }
            self?.enviarPedaco(de: leitor, por: connection)
        }))
    }

    /// `attachment` com o nome original, acentos inclusive (RFC 6266 / RFC 5987), e um
    /// nome só em ASCII de reserva para navegadores antigos.
    static func disposicao(para nome: String) -> String {
        // Na reserva só ASCII: "Lógica" vira "Logica", e o que não tiver equivalente vira "_".
        let semAcentos = nome.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let reserva = String(semAcentos.unicodeScalars.map { escalar -> Character in
            let v = escalar.value
            if v < 0x20 || v > 0x7E || escalar == "\"" || escalar == "\\" { return "_" }
            return Character(escalar)
        })
        var permitidos = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        permitidos.insert(charactersIn: "!#$&+-.^_`|~")
        let codificado = nome.addingPercentEncoding(withAllowedCharacters: permitidos) ?? reserva
        return "attachment; filename=\"\(reserva)\"; filename*=UTF-8''\(codificado)"
    }

    private func enviarNaoEncontrado(_ connection: NWConnection) {
        let corpo = "Arquivo não disponível. O professor pode tê-lo removido."
        let cabecalho = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(corpo.utf8.count)\r\nConnection: close\r\n\r\n"
        var resposta = Data(cabecalho.utf8)
        resposta.append(Data(corpo.utf8))
        connection.send(content: resposta, completion: .contentProcessed({ _ in connection.cancel() }))
    }
}
