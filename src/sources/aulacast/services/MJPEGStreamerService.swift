import Foundation
import Network

/// Servico responsavel exclusivamente pelo streaming de video MJPEG em malha aberta (SRP).
public final class MJPEGStreamerService {
    private var latestFrameData: Data?
    private var frameSequence: UInt64 = 0
    private let frameLock = NSLock()

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

        connection.send(content: Data(headers.utf8), completion: .contentProcessed({ [weak self] _ in
            self?.streamLoop(connection: connection, lastSentSequence: 0)
        }))
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
                connection.cancel()
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
            guard error == nil else {
                // O aluno saiu ou a rede caiu: encerrar explicitamente, senão a conexão
                // fica pendurada até o app fechar (uma por aluno que sai da aula).
                connection.cancel()
                return
            }
            self?.streamLoop(connection: connection, lastSentSequence: currentSequence)
        }))
    }
}
