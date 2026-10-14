import Foundation
import CoreMedia

/// Um quadro H.264 já codificado, em Annex-B (cada NAL prefixado por start code
/// 0x00 0x00 0x00 0x01). Quando `isKeyFrame`, `data` inclui SPS e PPS antes do IDR slice —
/// o suficiente para o empacotador fMP4 montar o `avcC` sem precisar de mais nada.
public struct H264AccessUnit {
    public let data: Data
    public let presentationTime: CMTime
    public let isKeyFrame: Bool
    /// Dimensões do quadro codificado — vêm prontas do encoder (via `CMVideoFormatDescription`)
    /// para o empacotador fMP4 não precisar decodificar o SPS (Exp-Golomb) só para saber
    /// largura/altura.
    public let width: Int32
    public let height: Int32
    /// Fps nominal da captura: o empacotador deriva daqui o período nominal de um quadro.
    public let framesPerSecond: Int

    public init(data: Data, presentationTime: CMTime, isKeyFrame: Bool, width: Int32, height: Int32,
                framesPerSecond: Int = 30) {
        self.framesPerSecond = framesPerSecond
        self.data = data
        self.presentationTime = presentationTime
        self.isKeyFrame = isKeyFrame
        self.width = width
        self.height = height
    }
}

/// Quem recebe os access units do encoder H.264 (o empacotador fMP4).
public protocol H264AccessUnitReceiverProtocol: AnyObject {
    func didReceiveAccessUnit(_ unit: H264AccessUnit)
}
