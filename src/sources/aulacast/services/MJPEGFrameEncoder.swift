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

        // Copia os bytes do pixel buffer aqui: o ScreenCaptureKit reaproveita os buffers do pool,
        // então segurá-los em outra fila trava a captura.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cgImage = makeCGImage(from: pixelBuffer) else {
            markIdle()
            return
        }

        encodingQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.markIdle() }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let jpegData = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: self.compressionQuality]
            ) else { return }

            self.outputReceiver?.didReceiveEncodedFrame(data: jpegData, isKeyFrame: true)
        }
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    private func markIdle() {
        busyLock.lock()
        isEncoding = false
        busyLock.unlock()
    }
}
