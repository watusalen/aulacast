import Foundation

/// Resolução de saída configurável para a transmissão de tela.
public enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case p720 = "720p"
    case p1080 = "1080p"

    public var id: String { rawValue }

    public var width: Int32 {
        switch self {
        case .p720: return 1280
        case .p1080: return 1920
        }
    }

    public var height: Int32 {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        }
    }
}
