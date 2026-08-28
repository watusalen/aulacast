import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Gera o QR Code do endereço da aula (SRP).
///
/// Existe porque digitar `http://192.168.31.127:8080` numa turma inteira é onde a aula
/// trava: um aluno erra um dígito, outro esquece a porta, e o professor vira suporte técnico
/// antes de começar. Com o código na tela, quem tem celular aponta a câmera e entra; quem
/// está no computador ainda pode digitar, porque o endereço continua escrito do lado.
public enum QRCodeGenerator {
    /// Imagem do QR Code para o texto dado, ou `nil` se não houver o que codificar.
    public static func imagem(para texto: String, lado: CGFloat = 240) -> NSImage? {
        let conteudo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conteudo.isEmpty, lado > 0 else { return nil }

        let filtro = CIFilter.qrCodeGenerator()
        filtro.message = Data(conteudo.utf8)
        // "M" corrige até 15% do código danificado: o suficiente para uma foto tremida de
        // celular a três metros do projetor, sem inflar o desenho a ponto de virar poeira.
        filtro.correctionLevel = "M"

        guard let saida = filtro.outputImage else { return nil }

        // O filtro devolve um código minúsculo (uns 25 pontos de lado). Ampliar por número
        // inteiro mantém os quadradinhos com borda reta; ampliar por fração os deixa
        // borrados, e aí a câmera do aluno não lê.
        let escala = max(1, (lado / saida.extent.width).rounded(.down))
        let ampliada = saida.transformed(by: CGAffineTransform(scaleX: escala, y: escala))

        let contexto = CIContext()
        guard let cgImage = contexto.createCGImage(ampliada, from: ampliada.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: lado, height: lado))
    }
}
