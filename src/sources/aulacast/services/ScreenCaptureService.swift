import Foundation
import ScreenCaptureKit
import CoreMedia
import Combine

/// Serviço responsável estritamente pelo controle do streaming da ScreenCaptureKit (SRP, LSP).
public final class ScreenCaptureService: NSObject, ScreenCaptureProtocol {
    @Published public var availableSources: [DisplaySource] = []
    @Published public var isRecording: Bool = false
    @Published public var errorMessage: String?

    /// Trocar a fonte no meio da aula deve valer na hora, sem parar e reiniciar a transmissão.
    @Published public var selectedSource: DisplaySource? {
        didSet {
            guard isRecording, oldValue?.id != selectedSource?.id else { return }
            Task { await applyContentFilterChange() }
        }
    }

    /// Idem para a qualidade: mudar durante a transmissão precisa surtir efeito imediato.
    @Published public var resolution: VideoResolution = .p1080 {
        didSet {
            guard isRecording, oldValue != resolution else { return }
            Task { await applyConfigurationChange() }
        }
    }

    @Published public var frameRate: Int = 30 {
        didSet {
            guard isRecording, oldValue != frameRate else { return }
            Task { await applyConfigurationChange() }
        }
    }
    
    public weak var frameReceiver: FrameReceiverProtocol?
    public weak var lifecycleObserver: CaptureLifecycleObserverProtocol?
    
    private let contentFetcher: ShareableContentFetcher
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "br.com.ifpi.aulacast.captureQueue", qos: .userInteractive)
    
    public init(contentFetcher: ShareableContentFetcher = ShareableContentFetcher()) {
        self.contentFetcher = contentFetcher
        super.init()
    }
    
    public func fetchAvailableSources() async {
        do {
            let sources = try await contentFetcher.fetchSources()
            await MainActor.run {
                self.availableSources = sources
                if self.selectedSource == nil {
                    self.selectedSource = sources.first
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Erro ao buscar fontes: \(error.localizedDescription)"
            }
        }
    }
    
    public func startCapture() async {
        guard let source = selectedSource else {
            await MainActor.run {
                self.errorMessage = "Nenhuma fonte selecionada."
            }
            return
        }
        
        do {
            guard let filter = makeContentFilter(for: source) else { return }
            let config = makeConfiguration()

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            
            try await stream.startCapture()
            await MainActor.run {
                self.stream = stream
                self.isRecording = true
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Falha ao iniciar captura: \(error.localizedDescription)"
            }
        }
    }
    
    private func makeContentFilter(for source: DisplaySource) -> SCContentFilter? {
        if let scDisplay = source.scDisplay {
            return SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
        }
        if let scWindow = source.scWindow {
            return SCContentFilter(desktopIndependentWindow: scWindow)
        }
        return nil
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(resolution.width)
        config.height = Int(resolution.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    /// Troca a tela/janela transmitida sem derrubar a sessão: os alunos continuam conectados.
    private func applyContentFilterChange() async {
        guard let stream = self.stream,
              let source = selectedSource,
              let filter = makeContentFilter(for: source) else { return }
        do {
            try await stream.updateContentFilter(filter)
        } catch {
            await MainActor.run {
                self.errorMessage = "Não foi possível trocar a fonte: \(error.localizedDescription)"
            }
        }
    }

    /// Aplica resolução/taxa de quadros novas na transmissão em andamento.
    private func applyConfigurationChange() async {
        guard let stream = self.stream else { return }
        do {
            try await stream.updateConfiguration(makeConfiguration())
        } catch {
            await MainActor.run {
                self.errorMessage = "Não foi possível aplicar a qualidade: \(error.localizedDescription)"
            }
        }
    }

    public func stopCapture() async {
        guard let stream = self.stream else { return }
        do {
            try await stream.stopCapture()
            await MainActor.run {
                self.stream = nil
                self.isRecording = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Erro ao interromper captura: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate
extension ScreenCaptureService: SCStreamOutput, SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        frameReceiver?.didReceiveSampleBuffer(sampleBuffer)
    }
    
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let reason = error.localizedDescription
        Task { @MainActor in
            self.errorMessage = "Transmissão interrompida: \(reason)"
            self.isRecording = false
            self.stream = nil
            // Avisa quem controla a sessão: sem isto o app continuaria anunciando
            // "TRANSMITINDO AO VIVO" com a captura já morta.
            self.lifecycleObserver?.captureDidStopUnexpectedly(reason: reason)
        }
    }
}