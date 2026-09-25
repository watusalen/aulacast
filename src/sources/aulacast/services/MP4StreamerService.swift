import Foundation
import Network

/// Serviço responsável exclusivamente pelo streaming de vídeo fMP4 (H.264), irmão do
/// `MJPEGStreamerService` para o novo formato (SRP).
///
/// Diferença central para o MJPEG: lá, cada quadro é um JPEG independente — uma conexão lenta
/// pode simplesmente pular para o quadro mais recente sem prejuízo nenhum. Aqui, um P-frame
/// depende do quadro anterior: pular um fragmento no meio quebra a decodificação até o próximo
/// quadro-chave. Por isso cada conexão tem sua própria fila e recebe todo fragmento em ordem;
/// quem não consegue acompanhar é levado a re-sincronizar a partir do próximo quadro-chave, em
/// vez de ver a imagem corromper.
public final class MP4StreamerService: FMP4FragmentReceiverProtocol {
    private final class Conexao {
        let connection: NWConnection
        var fila: [Data] = []
        var enviando = false
        /// Começa em `true` para toda conexão nova: sem isto, ela poderia receber um P-frame
        /// como primeiro fragmento (se chegar antes do quadro-chave que `onNeedsKeyFrame` pediu),
        /// e o `SourceBuffer` do navegador não tem nada para decodificar aquilo.
        var aguardandoKeyFrame = true

        init(connection: NWConnection) { self.connection = connection }
    }

    private let lock = NSLock()
    private var conexoes: [ObjectIdentifier: Conexao] = [:]
    private var initSegment: Data?

    /// Fragmentos pendentes antes de descartar tudo e esperar o próximo quadro-chave. A 30fps,
    /// ~4s de atraso acumulado é o limite entre "a rede desse aluno está momentaneamente lenta"
    /// e "ele nunca mais vai alcançar — melhor recomeçar do zero".
    private static let filaMaxima = 120

    /// Chamado quando uma conexão nova chega: quem estiver ouvindo (o encoder H.264) deve
    /// forçar um quadro-chave o quanto antes, para o aluno não ficar sem imagem até o próximo
    /// quadro-chave "de rotina" (que pode demorar segundos).
    public var onNeedsKeyFrame: (() -> Void)?

    /// Quantos alunos estão com o vídeo H.264 aberto agora.
    public var activeStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return conexoes.count
    }

    public init() {}

    /// Esquece o segmento de inicialização. Chamado quando o servidor para, para que a
    /// próxima sessão não ofereça a um aluno novo o `avcC` de uma aula anterior.
    public func reset() {
        lock.lock()
        initSegment = nil
        lock.unlock()
    }

    public func serveStream(connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: video/mp4\r\n" +
                      "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                      "Pragma: no-cache\r\n" +
                      "Connection: close\r\n\r\n"

        let estado = Conexao(connection: connection)

        lock.lock()
        if let initSegment {
            estado.fila.append(initSegment)
        }
        conexoes[ObjectIdentifier(connection)] = estado
        lock.unlock()

        onNeedsKeyFrame?()

        connection.send(content: Data(headers.utf8), completion: .contentProcessed({ [weak self] erro in
            guard erro == nil else {
                self?.encerrar(connection)
                return
            }
            self?.bombear(connection)
        }))

        vigiarSaida(connection)
    }

    /// Mantém uma leitura pendente só para saber quando o navegador fecha a conexão — mesmo
    /// mecanismo do `MJPEGStreamerService` (ver os comentários lá para o porquê).
    private func vigiarSaida(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self?.vigiarSaida(connection)
        }
    }

    private func encerrar(_ connection: NWConnection) {
        connection.cancel()
        lock.lock()
        conexoes.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    /// Envia o próximo item da fila da conexão, se houver um e ela não estiver ocupada. O
    /// próximo só sai quando o anterior terminar (`.contentProcessed`) — é o backpressure que
    /// impede o acúmulo de fragmentos atrasados num aluno de rede lenta.
    private func bombear(_ connection: NWConnection) {
        lock.lock()
        guard let estado = conexoes[ObjectIdentifier(connection)] else {
            lock.unlock()
            return
        }
        guard !estado.enviando, !estado.fila.isEmpty else {
            lock.unlock()
            return
        }
        estado.enviando = true
        let proximo = estado.fila.removeFirst()
        lock.unlock()

        connection.send(content: proximo, completion: .contentProcessed({ [weak self] erro in
            guard let self else { return }
            guard erro == nil else {
                self.encerrar(connection)
                return
            }
            self.lock.lock()
            estado.enviando = false
            self.lock.unlock()
            self.bombear(connection)
        }))
    }

    public func didReceiveFragment(_ data: Data, isInitSegment: Bool, isKeyFrame: Bool) {
        lock.lock()

        if isInitSegment {
            // Distingue o primeiro init segment da sessão (ninguém tem `avcC` nenhum ainda,
            // então só falta ENTREGAR este a quem já está conectado) de uma mudança de
            // resolução ao vivo (quem já está com o <video> montado tem um `avcC` antigo
            // dentro do `SourceBuffer`, e não dá para trocar isso sem reconstruir o
            // `MediaSource` inteiro do lado do aluno).
            let mudandoDeResolucao = initSegment != nil
            initSegment = data
            let existentes = Array(conexoes.values)

            if mudandoDeResolucao {
                // Mais simples e mais robusto que tentar sincronizar a troca com cada cliente:
                // encerrar as conexões e deixar o player do aluno reconectar sozinho — ele já
                // sabe fazer isso (mesmo mecanismo de reconexão automática do MJPEG hoje) — e
                // pegar o init segment novo direto, sem estado velho.
                conexoes.removeAll()
                lock.unlock()
                existentes.forEach { $0.connection.cancel() }
                return
            }

            // Primeira vez: só entregar a quem já estava esperando (chegou antes do primeiro
            // quadro-chave existir) — sem desconectar ninguém.
            for estado in existentes { estado.fila.append(data) }
            lock.unlock()
            existentes.forEach { bombear($0.connection) }
            return
        }

        let alvos = Array(conexoes.values)
        for estado in alvos {
            if estado.aguardandoKeyFrame {
                guard isKeyFrame else { continue }
                estado.aguardandoKeyFrame = false
            }
            if estado.fila.count >= Self.filaMaxima {
                estado.fila.removeAll()
                estado.aguardandoKeyFrame = true
                continue
            }
            estado.fila.append(data)
        }
        lock.unlock()

        for estado in alvos {
            bombear(estado.connection)
        }
    }
}
