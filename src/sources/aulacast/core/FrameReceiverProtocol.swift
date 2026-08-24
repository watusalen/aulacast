import Foundation
import CoreMedia

/// Interface para componentes que recebem quadros brutos de vídeo (ISP).
public protocol FrameReceiverProtocol: AnyObject {
    func didReceiveSampleBuffer(_ sampleBuffer: CMSampleBuffer)
}

/// Interface para componentes que recebem dados de vídeo codificados (ISP).
public protocol EncodedFrameReceiverProtocol: AnyObject {
    func didReceiveEncodedFrame(data: Data, isKeyFrame: Bool)
}