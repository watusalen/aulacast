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

                guard !self.isRecording else {
                    // Durante a transmissão a escolha não é mexida: se a janela transmitida
                    // for fechada, quem avisa é o próprio SCStream, com o motivo do erro.
                    return
                }

                // A janela escolhida pode ter sido fechada desde a última busca. Sem isto,
                // "Iniciar Transmissão" apontaria para uma janela que não existe mais.
                let escolhaSumiu = self.selectedSource.map { atual in
                    !sources.contains(where: { $0.id == atual.id })
                } ?? true

                if escolhaSumiu {
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
            guard let filter = await makeContentFilter(for: source) else { return }
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
    
    private func makeContentFilter(for source: DisplaySource) async -> SCContentFilter? {
        if let scDisplay = source.scDisplay {
            // Ao transmitir o monitor inteiro, a própria janela do AulaCast fica de fora.
            // Sem isto a turma veria o painel do professor — inclusive a lista com nomes e
            // matrículas dos colegas e a conversa privada — além do efeito de espelho
            // infinito causado pela prévia exibindo a si mesma.
            return SCContentFilter(
                display: scDisplay,
                excludingApplications: await aplicacoesDoProprioApp(),
                exceptingWindows: []
            )
        }
        if let scWindow = source.scWindow {
            return SCContentFilter(desktopIndependentWindow: scWindow)
        }
        return nil
    }

    /// O próprio aplicativo, identificado pelo processo — funciona tanto no app instalado
    /// quanto rodando via `swift run`, onde o bundle identifier é nulo.
    private func aplicacoesDoProprioApp() async -> [SCRunningApplication] {
        let processoAtual = ProcessInfo.processInfo.processIdentifier
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else {
            return []
        }
        return content.applications.filter { $0.processID == processoAtual }
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
              let filter = await makeContentFilter(for: source) else { return }
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

        // O ScreenCaptureKit entrega quadros que não carregam imagem nenhuma: quando a tela
        // do professor está parada ele manda `.idle` só para dizer "nada mudou", e manda
        // `.blank`/`.suspended` quando a captura está bloqueada. Repassá-los fazia o
        // codificador acordar à toa a cada um deles (e, na troca de fonte, chegar a produzir
        // um quadro vazio para a turma). Só `.complete` traz pixels novos de verdade.
        guard sampleBuffer.isValid, Self.temImagemNova(sampleBuffer) else { return }

        frameReceiver?.didReceiveSampleBuffer(sampleBuffer)
    }

    /// Na dúvida, deixa passar: se um dia o formato do anexo mudar, o pior que acontece é
    /// voltar ao comportamento antigo — e não a aula inteira sem imagem.
    private nonisolated static func temImagemNova(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let anexos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let bruto = anexos.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: bruto) else {
            return true
        }
        return status == .complete
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