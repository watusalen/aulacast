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
            return await filtroDeMonitor(scDisplay)
        }
        if let scWindow = source.scWindow {
            return SCContentFilter(desktopIndependentWindow: scWindow)
        }
        return nil
    }

    /// Monitor inteiro, com a janela do próprio AulaCast fora do quadro.
    ///
    /// Isto não é cosmético: o painel do professor mostra a conversa reservada com cada
    /// aluno e a lista da turma. Se ele entrar na transmissão, a sala inteira vê — além do
    /// espelho infinito da prévia exibindo a si mesma.
    ///
    /// Antes a exclusão falhava **em silêncio**: a consulta ao sistema era feita com `try?`
    /// e, quando não respondia, devolvia lista vazia — nada era excluído e a transmissão
    /// saía com o painel dentro, sem nenhum aviso. Aqui a consulta é tentada de novo e, se
    /// ainda assim falhar, a captura não começa: é melhor o professor ver um erro do que a
    /// turma ver o que não devia.
    private func filtroDeMonitor(_ display: SCDisplay) async -> SCContentFilter? {
        let processoAtual = ProcessInfo.processInfo.processIdentifier

        guard let conteudo = await conteudoCompartilhavel() else {
            await MainActor.run {
                self.errorMessage =
                    "Não foi possível preparar a captura sem expor a janela do AulaCast. "
                    + "Tente iniciar a transmissão de novo."
            }
            return nil
        }

        let nossosAplicativos = conteudo.applications.filter { $0.processID == processoAtual }
        if !nossosAplicativos.isEmpty {
            return SCContentFilter(
                display: display,
                excludingApplications: nossosAplicativos,
                exceptingWindows: []
            )
        }

        // O AulaCast pode não constar na lista de aplicativos compartilháveis (acontece
        // quando ele está minimizado ou a janela ainda não foi registrada). Excluir pelas
        // janelas chega ao mesmo resultado sem depender daquela lista — e uma lista vazia
        // aqui é legítima: sem janela na tela, não há o que esconder.
        let nossasJanelas = conteudo.windows.filter {
            $0.owningApplication?.processID == processoAtual
        }
        return SCContentFilter(display: display, excludingWindows: nossasJanelas)
    }

    /// Duas tentativas: logo depois de abrir o app a primeira consulta às vezes falha.
    private func conteudoCompartilhavel() async -> SCShareableContent? {
        for tentativa in 0..<2 {
            if let conteudo = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ) {
                return conteudo
            }
            if tentativa == 0 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
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

        // Nada de filtrar quadro aqui.
        //
        // Já houve um `guard` neste ponto descartando tudo que não fosse `SCFrameStatus
        // .complete`, com a ideia de poupar o codificador dos quadros "nada mudou". Na
        // prática a transmissão ficou travada e lenta: este é o caminho de cada quadro, e
        // errar o julgamento aqui não custa desempenho — custa a aula inteira.
        //
        // O desperdício que aquilo tentava evitar já é tratado onde dá para medir: o
        // codificador descarta quadro novo enquanto o anterior não terminou, e o streamer
        // MJPEG só envia quando a sequência muda.
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