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
    /// Item da fila de uma conexão. `media` é falso só para o segmento de inicialização.
    private struct Entrada {
        let data: Data
        let media: Bool
        let instante: DispatchTime
    }

    private final class Conexao {
        let connection: NWConnection
        var fila: [Entrada] = []
        var filaBytes = 0
        /// Começa em `true`: a conexão só é liberada para receber fragmentos depois que o
        /// cabeçalho HTTP saiu (senão o segmento de inicialização podia passar à frente dele).
        var enviando = true
        /// Começa em `true` para toda conexão nova: sem isto, ela poderia receber um P-frame
        /// como primeiro fragmento (se chegar antes do quadro-chave que `onNeedsKeyFrame` pediu),
        /// e o `SourceBuffer` do navegador não tem nada para decodificar aquilo.
        var aguardandoKeyFrame = true

        init(connection: NWConnection) { self.connection = connection }

        func enfileirar(_ entrada: Entrada) {
            fila.append(entrada)
            filaBytes += entrada.data.count
        }

        func desenfileirar() -> Entrada {
            let entrada = fila.removeFirst()
            filaBytes -= entrada.data.count
            return entrada
        }

        /// Descarta os fragmentos de mídia pendentes, mas guarda um segmento de inicialização
        /// ainda não enviado (sem ele o aluno não decodifica nada, mesmo ressincronizando).
        func descartarMidia() {
            fila.removeAll { $0.media }
            filaBytes = fila.reduce(0) { $0 + $1.data.count }
        }
    }

    private let lock = NSLock()
    private var conexoes: [ObjectIdentifier: Conexao] = [:]
    private var initSegment: Data?

    /// Limites da fila de cada aluno: ~1 MB e ~1 s de fragmentos. Passou de qualquer um, ele
    /// não vai alcançar: descarta tudo e recomeça no próximo quadro-chave, em vez de acumular
    /// memória e atraso (com a tela parada, 120 fragmentos pequenos podiam significar 30 s).
    static let filaMaxBytes = 1_000_000
    private static let filaMaxIdadeNs: UInt64 = 1_000_000_000

    /// Chamado quando um quadro-chave faz falta (aluno novo, ou aluno que perdeu a sincronia):
    /// quem estiver ouvindo (o encoder H.264) deve forçar um quadro-chave. Os pedidos são
    /// agrupados (`pedirKeyFrame`).
    public var onNeedsKeyFrame: (() -> Void)?

    // MARK: - Agrupamento dos pedidos de quadro-chave

    /// Janela mínima entre dois pedidos. Sem isto, um aluno abrindo e fechando `/stream.mp4` em
    /// laço forçaria um quadro-chave (muito maior que um P-frame) em quase todo quadro, e a banda
    /// de toda a turma multiplicaria.
    private let janelaDeKeyFrame: TimeInterval
    private let keyFrameLock = NSLock()
    private var ultimoPedidoDeKeyFrame: DispatchTime?
    private var pedidoAdiado = false

    /// Pede um quadro-chave, no máximo um por janela. Um pedido dentro da janela é adiado para o
    /// fim dela (não se perde). O(1).
    private func pedirKeyFrame() {
        keyFrameLock.lock()
        let agora = DispatchTime.now()
        if let ultimo = ultimoPedidoDeKeyFrame {
            let decorrido = Double(agora.uptimeNanoseconds &- ultimo.uptimeNanoseconds) / 1_000_000_000
            if decorrido < janelaDeKeyFrame {
                if !pedidoAdiado {
                    pedidoAdiado = true
                    DispatchQueue.global().asyncAfter(deadline: .now() + (janelaDeKeyFrame - decorrido)) { [weak self] in
                        self?.dispararPedidoAdiado()
                    }
                }
                keyFrameLock.unlock()
                return
            }
        }
        ultimoPedidoDeKeyFrame = agora
        keyFrameLock.unlock()
        onNeedsKeyFrame?()
    }

    private func dispararPedidoAdiado() {
        keyFrameLock.lock()
        pedidoAdiado = false
        ultimoPedidoDeKeyFrame = DispatchTime.now()
        keyFrameLock.unlock()
        onNeedsKeyFrame?()
    }

    // MARK: - Contadores

    private var contadores = StreamSnapshot()
    /// Número de série de cada conexão aberta (nunca reaproveitado); ver `StreamSnapshot.quadrosPorAluno`.
    private var serieDaConexao: [ObjectIdentifier: UInt64] = [:]
    private var proximaSerie: UInt64 = 0
    private let contadoresLock = NSLock()

    /// Fotografia dos contadores. A diferença entre duas delas dá as taxas (`StreamRates`).
    public func snapshot() -> StreamSnapshot {
        contadoresLock.lock()
        defer { contadoresLock.unlock() }
        return contadores
    }

    /// Soma um envio concluído. Só fragmentos de mídia contam como "quadro" do aluno; o
    /// cabeçalho HTTP e o segmento de inicialização contam apenas em bytes.
    private func contar(bytes: Int, fragmentoDeMidia: Bool, de connection: NWConnection) {
        contadoresLock.lock()
        defer { contadoresLock.unlock() }
        contadores.bytesEnviados &+= UInt64(bytes)
        if fragmentoDeMidia, let serie = serieDaConexao[ObjectIdentifier(connection)],
           let quadros = contadores.quadrosPorAluno[serie] {
            contadores.quadrosPorAluno[serie] = quadros &+ 1
        }
    }

    private func esquecerSerie(de connection: NWConnection) {
        contadoresLock.lock()
        if let serie = serieDaConexao.removeValue(forKey: ObjectIdentifier(connection)) {
            contadores.quadrosPorAluno.removeValue(forKey: serie)
        }
        contadoresLock.unlock()
    }

    /// Quantos alunos estão com o vídeo H.264 aberto agora.
    public var activeStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return conexoes.count
    }

    public init(janelaDeKeyFrame: TimeInterval = 1.0) {
        self.janelaDeKeyFrame = janelaDeKeyFrame
    }

    /// Esquece o segmento de inicialização e derruba os alunos conectados. Chamado quando o
    /// servidor para, para que a próxima sessão não ofereça a um aluno novo o `avcC` de uma aula
    /// anterior nem herde conexões e contadores velhos.
    public func reset() {
        lock.lock()
        initSegment = nil
        let existentes = Array(conexoes.values)
        conexoes.removeAll()
        lock.unlock()

        derrubar(existentes)
    }

    private func derrubar(_ estados: [Conexao]) {
        for estado in estados {
            esquecerSerie(de: estado.connection)
            estado.connection.cancel()
        }
    }

    public func serveStream(connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: video/mp4\r\n" +
                      "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                      "Pragma: no-cache\r\n" +
                      "Connection: close\r\n\r\n"
        let cabecalho = Data(headers.utf8)

        let estado = Conexao(connection: connection)

        contadoresLock.lock()
        proximaSerie &+= 1
        serieDaConexao[ObjectIdentifier(connection)] = proximaSerie
        contadores.quadrosPorAluno[proximaSerie] = 0
        contadoresLock.unlock()

        lock.lock()
        if let initSegment {
            estado.enfileirar(Entrada(data: initSegment, media: false, instante: .now()))
        }
        conexoes[ObjectIdentifier(connection)] = estado
        lock.unlock()

        pedirKeyFrame()

        connection.send(content: cabecalho, completion: .contentProcessed({ [weak self] erro in
            guard let self else { return }
            guard erro == nil else {
                self.encerrar(connection)
                return
            }
            self.contar(bytes: cabecalho.count, fragmentoDeMidia: false, de: connection)
            self.lock.lock()
            estado.enviando = false
            self.lock.unlock()
            self.bombear(connection)
        }))

        vigiarSaida(connection)
    }

    /// Mantém uma leitura pendente só para saber quando o navegador fecha a conexão — mesmo
    /// mecanismo do `MJPEGStreamerService` (ver os comentários lá para o porquê).
    private func vigiarSaida(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                // Só cancelar deixaria a conexão em `conexoes` (e contada) enquanto a tela
                // estiver parada ou em pausa, sem nenhum envio para falhar.
                if let self {
                    self.encerrar(connection)
                } else {
                    connection.cancel()
                }
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
        esquecerSerie(de: connection)
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
        let proximo = estado.desenfileirar()
        lock.unlock()

        connection.send(content: proximo.data, completion: .contentProcessed({ [weak self] erro in
            guard let self else { return }
            guard erro == nil else {
                self.encerrar(connection)
                return
            }
            self.contar(bytes: proximo.data.count, fragmentoDeMidia: proximo.media, de: connection)
            self.lock.lock()
            estado.enviando = false
            self.lock.unlock()
            self.bombear(connection)
        }))
    }

    public func didReceiveFragment(_ data: Data, isInitSegment: Bool, isKeyFrame: Bool) {
        if !isInitSegment {
            contadoresLock.lock()
            contadores.quadrosPublicados &+= 1
            contadoresLock.unlock()
        }

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
                derrubar(existentes)
                return
            }

            // Primeira vez: só entregar a quem já estava esperando (chegou antes do primeiro
            // quadro-chave existir) — sem desconectar ninguém.
            let entrada = Entrada(data: data, media: false, instante: .now())
            for estado in existentes { estado.enfileirar(entrada) }
            lock.unlock()
            existentes.forEach { bombear($0.connection) }
            return
        }

        let agora = DispatchTime.now()
        let entrada = Entrada(data: data, media: true, instante: agora)
        var precisaDeKeyFrame = false
        let alvos = Array(conexoes.values)
        for estado in alvos {
            if estado.aguardandoKeyFrame, !isKeyFrame { continue }

            if let maisAntigo = estado.fila.first {
                let idade = agora.uptimeNanoseconds &- maisAntigo.instante.uptimeNanoseconds
                if estado.filaBytes + data.count > Self.filaMaxBytes || idade > Self.filaMaxIdadeNs {
                    // Aluno que não acompanha: descarta tudo. Um quadro-chave já serve de ponto
                    // de ressincronização; um P-frame não, então espera o próximo.
                    estado.descartarMidia()
                    if !isKeyFrame {
                        estado.aguardandoKeyFrame = true
                        precisaDeKeyFrame = true
                        continue
                    }
                }
            }
            estado.aguardandoKeyFrame = false
            estado.enfileirar(entrada)
        }
        lock.unlock()

        if precisaDeKeyFrame { pedirKeyFrame() }
        for estado in alvos {
            bombear(estado.connection)
        }
    }
}
