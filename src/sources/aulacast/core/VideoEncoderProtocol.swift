import Foundation
import CoreMedia

/// Abstração para codificadores de vídeo (DIP / OCP).
public protocol VideoEncoderProtocol: AnyObject {
    var outputReceiver: EncodedFrameReceiverProtocol? { get set }
    func encode(sampleBuffer: CMSampleBuffer)
}