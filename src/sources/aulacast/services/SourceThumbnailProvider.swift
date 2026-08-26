import Foundation
import CoreGraphics
import AppKit

/// Captura uma imagem estática de um monitor ou janela (SRP).
///
/// Usado tanto pelos cards do seletor quanto pela prévia grande do painel: antes de
/// transmitir, o professor precisa ver a fonte escolhida para conferir se acertou a tela.
public struct SourceThumbnailProvider {
    public init() {}

    public func thumbnail(for source: DisplaySource) -> NSImage? {
        if let display = source.scDisplay {
            guard let cgImage = CGDisplayCreateImage(display.displayID) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        if let window = source.scWindow {
            guard let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                window.windowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return nil
    }
}
