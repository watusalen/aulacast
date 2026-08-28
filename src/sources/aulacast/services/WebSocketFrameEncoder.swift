import Foundation

/// Monta frames RFC 6455 no sentido servidor -> cliente (sem máscara).
///
/// Fica separado do serviço de conexão pelo mesmo motivo do decodificador: assim a
/// montagem do frame pode ser exercitada por teste, sem rede no meio.
public enum WebSocketFrameEncoder {
    /// Frame de texto único (FIN + opcode 0x1).
    ///
    /// O comprimento estendido de 8 bytes existe de propósito: antes, qualquer texto acima
    /// de 65535 bytes era simplesmente **descartado sem aviso** — o professor mandava a
    /// mensagem, via o próprio texto no painel dele e a turma nunca recebia nada.
    public static func textFrame(_ text: String) -> Data {
        payloadFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    /// Pong de controle (opcode 0xA) devolvendo o payload do ping, como manda a RFC 6455.
    public static func pongFrame(payload: Data) -> Data {
        payloadFrame(opcode: 0xA, payload: payload)
    }

    private static func payloadFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F)) // FIN + opcode

        let contagem = payload.count
        if contagem <= 125 {
            frame.append(UInt8(contagem))
        } else if contagem <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((contagem >> 8) & 0xFF))
            frame.append(UInt8(contagem & 0xFF))
        } else {
            frame.append(127)
            for deslocamento in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((contagem >> deslocamento) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }
}
