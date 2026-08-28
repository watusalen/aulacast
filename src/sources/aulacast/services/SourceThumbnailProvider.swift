import Foundation
import CoreGraphics
import AppKit

/// Captura uma imagem estática de um monitor ou janela (SRP).
///
/// Usado tanto pelos cards do seletor quanto pela prévia grande do painel: antes de
/// transmitir, o professor precisa ver a fonte escolhida para conferir se acertou a tela.
public struct SourceThumbnailProvider {
    /// Largura máxima da miniatura em pontos.
    ///
    /// O seletor mostra cartões de pouco mais de 200 pontos e a prévia grande não passa de
    /// 900. Guardar o quadro em resolução nativa não melhorava nada na tela e cobrava caro:
    /// numa varredura com dez janelas abertas em um monitor 5K eram dez imagens de dezenas
    /// de megabytes cada, recriadas a cada cinco segundos e mantidas todas em memória —
    /// disputando exatamente a CPU e a memória de que a transmissão precisa.
    public static let larguraMaxima: CGFloat = 960

    private let larguraMaxima: CGFloat

    public init(larguraMaxima: CGFloat = SourceThumbnailProvider.larguraMaxima) {
        self.larguraMaxima = larguraMaxima
    }

    public func thumbnail(for source: DisplaySource) -> NSImage? {
        if let display = source.scDisplay {
            guard let cgImage = CGDisplayCreateImage(display.displayID) else { return nil }
            return imagemReduzida(de: cgImage)
        }

        if let window = source.scWindow {
            guard let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                window.windowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) else { return nil }
            return imagemReduzida(de: cgImage)
        }

        return nil
    }

    /// Tamanho de exibição respeitando o teto de largura, preservando a proporção.
    /// Imagens já menores que o teto passam intactas.
    public static func tamanhoExibido(
        largura: Int,
        altura: Int,
        larguraMaxima: CGFloat = SourceThumbnailProvider.larguraMaxima
    ) -> NSSize {
        guard largura > 0, altura > 0 else { return NSSize(width: 0, height: 0) }
        guard CGFloat(largura) > larguraMaxima else {
            return NSSize(width: largura, height: altura)
        }
        let escala = larguraMaxima / CGFloat(largura)
        return NSSize(
            width: larguraMaxima,
            height: max(1, (CGFloat(altura) * escala).rounded())
        )
    }

    private func imagemReduzida(de cgImage: CGImage) -> NSImage? {
        let tamanho = Self.tamanhoExibido(
            largura: cgImage.width,
            altura: cgImage.height,
            larguraMaxima: larguraMaxima
        )
        guard tamanho.width >= 1, tamanho.height >= 1 else { return nil }

        let largura = Int(tamanho.width)
        let altura = Int(tamanho.height)

        guard largura < cgImage.width else {
            return NSImage(cgImage: cgImage, size: tamanho)
        }

        // Redesenha de fato em tamanho menor: trocar só o `size` do NSImage manteria os
        // pixels originais na memória, que é justamente o custo que se quer evitar.
        //
        // O desenho é feito em CoreGraphics, e não com `lockFocus`, porque esta varredura
        // roda fora da thread principal para não travar a interface — e as APIs de desenho
        // do AppKit não são feitas para isso.
        guard let espacoDeCor = CGColorSpace(name: CGColorSpace.sRGB),
              let contexto = CGContext(
                data: nil,
                width: largura,
                height: altura,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: espacoDeCor,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return NSImage(cgImage: cgImage, size: tamanho)
        }

        contexto.interpolationQuality = .medium
        contexto.draw(cgImage, in: CGRect(x: 0, y: 0, width: largura, height: altura))

        guard let reduzida = contexto.makeImage() else {
            return NSImage(cgImage: cgImage, size: tamanho)
        }
        return NSImage(cgImage: reduzida, size: tamanho)
    }
}
