import Foundation
import Network

/// Servico responsavel exclusivamente pelo streaming de video MJPEG em malha aberta (SRP).
public final class MJPEGStreamerService {
    private var latestFrameData: Data?
    private var frameSequence: UInt64 = 0
    private let frameLock = NSLock()

    private var streamsAtivos = 0
    private let streamsLock = NSLock()

    /// Quantos alunos estão com o vídeo aberto agora. Existe para que a saída de um aluno
    /// possa ser observada de fora — inclusive por teste.
    public var activeStreamCount: Int {
        streamsLock.lock()
        defer { streamsLock.unlock() }
        return streamsAtivos
    }

    public init() {}

    public func updateFrame(_ data: Data) {
        frameLock.lock()
        self.latestFrameData = data
        self.frameSequence &+= 1
        frameLock.unlock()
    }

    /// Uma conexão de vídeo em andamento. O encerramento passa por aqui para acontecer uma
    /// única vez, mesmo quando a queda é percebida por dois caminhos ao mesmo tempo (a
    /// escuta do fim da conexão e a falha do próximo envio).
    private final class StreamSession {
        let connection: NWConnection
        private let trava = NSLock()
        private var encerrada = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        /// Verdadeiro apenas na primeira chamada.
        func marcarEncerrada() -> Bool {
            trava.lock()
            defer { trava.unlock() }
            if encerrada { return false }
            encerrada = true
            return true
        }
    }

    public func serveStream(connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: multipart/x-mixed-replace; boundary=--frame\r\n" +
                      "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                      "Pragma: no-cache\r\n" +
                      "Connection: close\r\n\r\n"

        let sessao = StreamSession(connection: connection)

        streamsLock.lock()
        streamsAtivos += 1
        streamsLock.unlock()

        // Vigia o fim da conexão em paralelo ao envio.
        //
        // O aluno que fecha a aba não avisa nada pela via do vídeo: ele apenas fecha o
        // socket. Enquanto a tela do professor está parada, nada é enviado — e sem envio não
        // há erro de envio para perceber a saída. O resultado era uma conexão pendurada por
        // aluno que saiu, cada uma girando o laço a cada 10 ms, até que um quadro novo
        // finalmente falhasse. Numa aula com entra-e-sai isso se acumula.
        vigiarFim(sessao)

        connection.send(content: Data(headers.utf8), completion: .contentProcessed({ [weak self] erro in
            guard erro == nil else {
                self?.encerrar(sessao)
                return
            }
            self?.streamLoop(sessao: sessao, lastSentSequence: 0)
        }))
    }

    /// Leitura contínua que só serve para notar o fim da conexão: o navegador não manda
    /// nada por aqui depois do GET, então qualquer conclusão ou erro significa que o aluno
    /// saiu.
    private func vigiarFim(_ sessao: StreamSession) {
        sessao.connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, erro in
            guard let self = self else { return }
            guard !isComplete, erro == nil else {
                self.encerrar(sessao)
                return
            }
            self.vigiarFim(sessao)
        }
    }

    private func encerrar(_ sessao: StreamSession) {
        guard sessao.marcarEncerrada() else { return }

        sessao.connection.cancel()

        streamsLock.lock()
        streamsAtivos = max(0, streamsAtivos - 1)
        streamsLock.unlock()
    }

    /// Envia apenas quadros novos. Reenviar o último quadro em loop desperdiçaria banda da LAN
    /// (a imagem no navegador já permanece congelada sozinha quando nada é enviado), o que é
    /// justamente o que sustenta o modo "pausado" sem tratamento especial.
    private func streamLoop(sessao: StreamSession, lastSentSequence: UInt64) {
        let connection = sessao.connection

        frameLock.lock()
        let currentFrame = latestFrameData
        let currentSequence = frameSequence
        frameLock.unlock()

        guard let jpeg = currentFrame, currentSequence != lastSentSequence else {
            // Enquanto a tela do professor está parada nada é enviado, então é aqui que
            // precisamos notar que o aluno saiu — do contrário este laço giraria para sempre.
            switch connection.state {
            case .cancelled, .failed:
                encerrar(sessao)
                return
            default:
                break
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.streamLoop(sessao: sessao, lastSentSequence: lastSentSequence)
            }
            return
        }

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
                self.encerrar(sessao)
                return
            }
            self.streamLoop(sessao: sessao, lastSentSequence: currentSequence)
        }))
    }
}
