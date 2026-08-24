import Foundation
import ScreenCaptureKit

/// Tipo de fonte de captura de vídeo no macOS.
public enum CaptureSourceType: String, Codable {
    case display = "Monitor Completo"
    case window = "Janela de Aplicativo"
}

/// Representa um monitor ou janela de app disponível para captura.
public struct DisplaySource: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let type: CaptureSourceType
    public let scDisplay: SCDisplay?
    public let scWindow: SCWindow?
    
    public init(scDisplay: SCDisplay) {
        self.id = "display-\(scDisplay.displayID)"
        self.name = "Monitor \(scDisplay.displayID) (\(scDisplay.width)x\(scDisplay.height))"
        self.type = .display
        self.scDisplay = scDisplay
        self.scWindow = nil
    }
    
    public init(scWindow: SCWindow) {
        self.id = "window-\(scWindow.windowID)"
        let appName = scWindow.owningApplication?.applicationName ?? "App"
        let title = scWindow.title ?? "Janela sem título"
        self.name = "[\(appName)] \(title)"
        self.type = .window
        self.scDisplay = nil
        self.scWindow = scWindow
    }
}