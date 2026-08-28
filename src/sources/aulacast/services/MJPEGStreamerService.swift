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

    public func updateFrame(_ data: Data) {
        frameLock.lock()
        self.latestFrameData = data
        self.frameSequence &+= 1
        frameLock.unlock()
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
        frameLock.unlock()

        guard let jpeg = currentFrame, currentSequence != lastSentSequence else {
            // Enquanto a tela do professor está parada nada é enviado, então é aqui que
            // precisamos notar que o aluno saiu — do contrário este laço giraria para sempre.
            switch connection.state {
            case .cancelled, .failed:
                encerrar(connection)
                return
            default:
                break
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.streamLoop(connection: connection, lastSentSequence: lastSentSequence)
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
                self.encerrar(connection)
                return
            }
            self.streamLoop(connection: connection, lastSentSequence: currentSequence)
        }))
    }
}
