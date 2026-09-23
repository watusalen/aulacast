import Foundation
import CoreMedia
import CoreImage
import ImageIO
import AppKit

/// Serviço responsável exclusivamente pela codificação MJPEG de quadros de vídeo (SRP, OCP, LSP).
public final class MJPEGFrameEncoder: VideoEncoderProtocol {
    public weak var outputReceiver: EncodedFrameReceiverProtocol?

    private let encodingQueue = DispatchQueue(label: "br.com.ifpi.aulacast.mjpegQueue", qos: .userInitiated)
    private let compressionQuality: CGFloat

    /// Criar um CIContext é caro (compila shaders e aloca recursos de GPU); reaproveitar
    /// a mesma instância entre quadros é o que mantém a codificação em tempo real.
    private let ciContext: CIContext

    /// Descarta quadros novos enquanto o anterior ainda está sendo codificado. Sem isso, uma
    /// codificação mais lenta que a captura enfileira quadros indefinidamente e o atraso cresce sem parar.
    private let busyLock = NSLock()
    private var isEncoding = false

    /// Espaço de cor do JPEG: o que os navegadores assumem quando a imagem não diz nada.
    private let espacoDeCor = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(compressionQuality: CGFloat = 0.6) {
        self.compressionQuality = compressionQuality
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        busyLock.lock()
        if isEncoding {
            busyLock.unlock()
            return
        }
        isEncoding = true
        busyLock.unlock()

        // Quadros `.idle` (tela parada) e `.suspended` (janela sumiu) chegam sem imagem:
        // é aqui que eles morrem, sem custo nenhum.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            markIdle()
            return
        }

        // O JPEG sai direto do pixel buffer, ainda nesta fila: o ScreenCaptureKit reaproveita
        // os buffers do pool, então eles não devem ficar presos em outra fila.
        //
        // Antes o caminho era pixel buffer -> CGImage -> NSBitmapImageRep -> JPEG. Medido
        // num quadro 1920x1080 real desta máquina: 6,0 ms de CPU por quadro, contra 1,0 ms
        // aqui, com o mesmo tamanho de arquivo — a 30 fps, de ~18% para ~3% de um núcleo.
        let jpeg = codificar(pixelBuffer)

        encodingQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.markIdle() }
            guard let jpeg else { return }
            self.outputReceiver?.didReceiveEncodedFrame(data: jpeg, isKeyFrame: true)
        }
    }

    private func codificar(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let imagem = CIImage(cvPixelBuffer: pixelBuffer)
        let opcoes: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                compressionQuality
        ]
        if let jpeg = ciContext.jpegRepresentation(of: imagem, colorSpace: espacoDeCor, options: opcoes) {
            return jpeg
        }

        // Há relato de versões do macOS em que esse caminho devolve nil com a opção de
        // qualidade. Aí vale o caminho antigo, mais caro, em vez de a turma ficar sem imagem.
        guard let cgImage = ciContext.createCGImage(imagem, from: imagem.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }

    private func markIdle() {
        busyLock.lock()
        isEncoding = false
        busyLock.unlock()
    }
}
