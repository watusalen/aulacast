import Foundation
import Network

/// Servico responsavel exclusivamente pelo streaming de video MJPEG em malha aberta (SRP).
public final class MJPEGStreamerService {
    private var latestFrameData: Data?
    private var frameSequence: UInt64 = 0
    private let frameLock = NSLock()

    private var streamsAtivos = 0
    private let streamsLock = NSLock()

    /// Quantos alunos estão com o vídeo aberto agora.
    ///
    /// A entrada e a saída de cada aluno passam a ser observáveis de fora: é o que permite
    /// afirmar por teste que ninguém fica pendurado depois de fechar a aba — inclusive no
    /// caso mais escorregadio, o da tela do professor parada, em que nenhum quadro é enviado
    /// e portanto nenhum envio falha para denunciar a saída.
    public var activeStreamCount: Int {
        streamsLock.lock()
        defer { streamsLock.unlock() }
        return streamsAtivos
    }

    public init() {}

    /// Conexões paradas esperando o próximo quadro.
    ///
    /// Protegidas pelo `frameLock`: registrar-se e conferir se há quadro novo precisam
    /// acontecer na mesma trava, senão um quadro publicado exatamente entre as duas coisas
    /// passa despercebido e a conexão dorme até o seguinte.
    ///
    /// Indexadas por uma ficha para que a batida de segurança retire a própria entrada. Antes
    /// era uma lista que só se esvaziava com quadro novo: com a tela parada, cada batida de
    /// 0,5 s empilhava mais um fechamento (segurando a conexão) por aluno, sem limite.
    private var esperandoQuadro: [UUID: () -> Void] = [:]

    public func updateFrame(_ data: Data) {
        frameLock.lock()
        self.latestFrameData = data
        self.frameSequence &+= 1
        let acordar = Array(esperandoQuadro.values)
        esperandoQuadro.removeAll()
        frameLock.unlock()

        // Fora da trava: cada um destes retoma o laço de envio, que vai querer a trava.
        for despertar in acordar {
            despertar()
        }
    }

    /// Esquece o último quadro. Chamado quando o servidor para, para que a próxima sessão
    /// não abra mostrando a tela da anterior.
    public func reset() {
        frameLock.lock()
        latestFrameData = nil
        frameLock.unlock()
    }

    /// Garante que cada conexão parada seja retomada uma única vez, venha o aviso pelo
    /// quadro novo ou pela batida de segurança.
    private final class Despertador {
        private let trava = NSLock()
        private var jaUsado = false

        func assumir() -> Bool {
            trava.lock()
            defer { trava.unlock() }
            if jaUsado { return false }
            jaUsado = true
            return true
        }
    }

    public func serveStream(connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: multipart/x-mixed-replace; boundary=--frame\r\n" +
                      "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                      "Pragma: no-cache\r\n" +
                      "Connection: close\r\n\r\n"

        streamsLock.lock()
        streamsAtivos += 1
        streamsLock.unlock()

        connection.send(content: Data(headers.utf8), completion: .contentProcessed({ [weak self] erro in
            guard erro == nil else {
                self?.encerrar(connection)
                return
            }
            self?.streamLoop(connection: connection, lastSentSequence: 0)
        }))

        vigiarSaida(connection)
    }

    /// Mantém uma leitura pendente só para saber quando o navegador fecha a conexão.
    ///
    /// Com a tela do professor parada nada é enviado, então nenhum envio falha para
    /// denunciar a saída — e o estado da conexão continua `.ready` depois do FIN do aluno.
    /// A conexão ficava em CLOSE_WAIT até a tela mudar. O navegador não manda nada depois
    /// do GET, então qualquer fim de leitura aqui é a saída dele.
    private func vigiarSaida(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                // Cancelar faz o laço de envio notar a saída (na batida de segurança ou no
                // próximo envio) e é lá que a contagem cai, uma vez só.
                connection.cancel()
                return
            }
            self?.vigiarSaida(connection)
        }
    }

    private func encerrar(_ connection: NWConnection) {
        connection.cancel()

        streamsLock.lock()
        streamsAtivos = max(0, streamsAtivos - 1)
        streamsLock.unlock()
    }

    /// Envia apenas quadros novos. Reenviar o último quadro em loop desperdiçaria banda da LAN
    /// (a imagem no navegador já permanece congelada sozinha quando nada é enviado), o que é
    /// justamente o que sustenta o modo "pausado" sem tratamento especial.
    private func streamLoop(connection: NWConnection, lastSentSequence: UInt64) {
        frameLock.lock()
        let currentFrame = latestFrameData
        let currentSequence = frameSequence

        guard let jpeg = currentFrame, currentSequence != lastSentSequence else {
            // Enquanto a tela do professor está parada nada é enviado, então é aqui que
            // precisamos notar que o aluno saiu — do contrário este laço giraria para sempre.
            switch connection.state {
            case .cancelled, .failed:
                frameLock.unlock()
                encerrar(connection)
                return
            default:
                break
            }

            // Antes esta espera era um cochilo de 10 ms: o laço acordava, perguntava se
            // havia quadro novo e dormia de novo. Isso encaixava a saída dos quadros numa
            // grade de 10 ms — a 60 fps o quadro fica pronto a cada 16,6 ms e saía com até
            // 10 ms de atraso variável, que é exatamente o que se enxerga como engasgo.
            //
            // Agora a conexão fica registrada e quem publica o quadro a acorda na hora.
            // A batida de segurança continua existindo, bem mais espaçada, só para notar o
            // aluno que fechou a aba com a tela do professor parada — aí nenhum quadro novo
            // vai chegar para acordar ninguém.
            let despertador = Despertador()
            let ficha = UUID()
            let retomar: () -> Void = { [weak self] in
                guard despertador.assumir() else { return }
                guard let self else { return }
                self.frameLock.lock()
                self.esperandoQuadro.removeValue(forKey: ficha)
                self.frameLock.unlock()
                self.streamLoop(connection: connection, lastSentSequence: lastSentSequence)
            }

            esperandoQuadro[ficha] = retomar
            frameLock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: retomar)
            return
        }
        frameLock.unlock()

        let frameHeader = "--frame\r\n" +
                          "Content-Type: image/jpeg\r\n" +
                          "Content-Length: \(jpeg.count)\r\n\r\n"

        var packet = Data(frameHeader.utf8)
        packet.append(jpeg)
        packet.append(Data("\r\n".utf8))

        // O próximo quadro só é enviado quando este termina de sair: é o backpressure que
        // impede o acúmulo de quadros atrasados em clientes de rede lenta.
        connection.send(content: packet, completion: .contentProcessed({ [weak self] error in
            guard let self = self else { return }
            guard error == nil else {
                // O aluno saiu ou a rede caiu: encerrar explicitamente, senão a conexão
                // fica pendurada até o app fechar (uma por aluno que sai da aula).
                self.encerrar(connection)
                return
            }
            self.streamLoop(connection: connection, lastSentSequence: currentSequence)
        }))
    }
}
