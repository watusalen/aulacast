import Foundation

/// Um frame WebSocket já decodificado (máscara removida).
public struct WebSocketFrame: Equatable {
    public let opcode: UInt8
    public let payload: Data

    public init(opcode: UInt8, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }

    public var isClose: Bool { opcode == 0x8 }
    public var isPing: Bool { opcode == 0x9 }
    public var isText: Bool { opcode == 0x1 }
}

/// Decodificador de frames RFC 6455 com buffer próprio (SRP: só entende o protocolo,
/// não sabe nada sobre conexões).
///
/// O buffer existe porque o TCP não respeita fronteira de mensagem: uma leitura pode trazer
/// dois frames colados ou apenas metade de um. Tratar cada leitura como exatamente um frame
/// fazia mensagens de chat serem descartadas em silêncio.
public final class WebSocketFrameDecoder {
    public enum Result: Equatable {
        /// Frames completos extraídos nesta rodada (pode vir vazio se faltam bytes).
        case frames([WebSocketFrame])
        /// Frame malformado ou grande demais: a conexão deve ser encerrada.
        case protocolViolation
    }

    enum SingleFrame: Equatable {
        case incomplete
        case invalid
        case frame(WebSocketFrame, consumed: Int)
    }

    private var buffer = Data()
    private let maxPayloadBytes: Int

    public init(maxPayloadBytes: Int = 1 << 20) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    /// Acrescenta os bytes recebidos e devolve todos os frames completos disponíveis.
    public func consume(_ bytes: Data) -> Result {
        buffer.append(bytes)

        var encontrados: [WebSocketFrame] = []

        while true {
            switch Self.parseSingleFrame(from: buffer, maxPayloadBytes: maxPayloadBytes) {
            case .incomplete:
                return .frames(encontrados)
            case .invalid:
                buffer.removeAll()
                return .protocolViolation
            case .frame(let frame, let consumed):
                buffer.removeFirst(consumed)
                encontrados.append(frame)
            }
        }
    }

    public func reset() {
        buffer.removeAll()
    }

    static func parseSingleFrame(from data: Data, maxPayloadBytes: Int) -> SingleFrame {
        guard data.count >= 2 else { return .incomplete }

        let base = data.startIndex
        let opcode = data[base] & 0x0F
        let secondByte = data[base + 1]
        let isMasked = (secondByte & 0x80) != 0
        var payloadLength = Int(secondByte & 0x7F)
        var offset = 2

        if payloadLength == 126 {
            guard data.count >= 4 else { return .incomplete }
            payloadLength = Int(data[base + 2]) << 8 | Int(data[base + 3])
            offset = 4
        } else if payloadLength == 127 {
            guard data.count >= 10 else { return .incomplete }
            var comprimento = 0
            for i in 0..<8 {
                // Sem este teto o valor estoura o Int e vira negativo; o intervalo
                // invertido que sairia daí derrubava o app do professor.
                guard comprimento <= (Int.max >> 8) else { return .invalid }
                comprimento = (comprimento << 8) | Int(data[base + 2 + i])
            }
            payloadLength = comprimento
            offset = 10
        }

        guard payloadLength >= 0, payloadLength <= maxPayloadBytes else { return .invalid }

        let tamanhoCabecalho = offset + (isMasked ? 4 : 0)
        let total = tamanhoCabecalho + payloadLength
        guard data.count >= total else { return .incomplete }

        let payload: Data
        if isMasked {
            let mascara = Array(data[(base + offset)..<(base + offset + 4)])
            let inicio = base + offset + 4
            var desmascarado = Data(capacity: payloadLength)
            for i in 0..<payloadLength {
                desmascarado.append(data[inicio + i] ^ mascara[i % 4])
            }
            payload = desmascarado
        } else {
            payload = data.subdata(in: (base + offset)..<(base + offset + payloadLength))
        }

        return .frame(WebSocketFrame(opcode: opcode, payload: payload), consumed: total)
    }
}
