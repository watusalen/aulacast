import SwiftUI

/// Transporta a imagem capturada entre tarefas. No macOS 13 o `NSImage` ainda não é
/// `Sendable`; aqui a instância é criada dentro da própria tarefa e entregue a um único
/// destino, sem ser compartilhada, então a travessia é segura.
private struct ImagemCapturada: @unchecked Sendable {
    let imagem: NSImage?
}

/// Janela principal de controle do aplicativo AulaCast para macOS.
public struct MainDashboardView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @State private var showQualitySettings = false


    /// Prévia da fonte escolhida enquanto a transmissão ainda não começou.
    @State private var previewDaFonteSelecionada: NSImage?

    public init() {}

    public var body: some View {
        dashboardContent
        // Reinicia a atualização quando a fonte muda ou quando a transmissão começa/para.
        .task(id: chavePrevia) {
            await manterPreviaDaFonteAtualizada()
        }
    }

    private var dashboardContent: some View {
        HSplitView {
            // Painel Esquerdo: Transmissao e Seletor.
            // Só a grade de fontes rola; o resto fica fixo e sempre visível.
            VStack(alignment: .leading, spacing: 22) {
                header
                livePreviewCard
                if let error = viewModel.streamErrorMessage {
                    streamErrorBanner(error)
                }
                actionButtonRow
                addressCard
                SourcePickerView(recorder: resolvedCaptureService)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(minWidth: 640, maxHeight: .infinity, alignment: .top)
            .background(AC.windowBG)

            // Painel Direito: Alunos e Chat (SRP e ISP)
            VSplitView {
                StudentListView(clientManager: viewModel.clientManager, serverURLString: viewModel.serverURLString)
                    .frame(minHeight: 220)

                ChatPanelView(viewModel: viewModel)
                    .frame(minHeight: 220)
            }
            .frame(minWidth: 340)
            .background(AC.panelBG)
        }
        .frame(minWidth: 1020, minHeight: 760)
    }

    /// Sem o nome do aplicativo: quem abriu já sabe onde está, e o ícone dá a identidade.
    /// O espaço fica para o estado da transmissão, que é o que muda e o que importa saber.
    private var header: some View {
        HStack(spacing: 12) {
            ACBrandMark(tamanho: 34)
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 9) {
            if viewModel.isStreaming {
                ACPulsingDot(color: AC.liveGreen, size: 10)
            } else {
                Circle()
                    .fill(AC.offlineRed)
                    .frame(width: 10, height: 10)
            }
            Text(viewModel.isStreaming ? "TRANSMITINDO AO VIVO" : "OFFLINE")
                .font(.system(size: 14, weight: .bold))
                .tracking(0.7)
                .foregroundColor(viewModel.isStreaming ? AC.liveGreen : AC.offlineRed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill((viewModel.isStreaming ? AC.liveGreen : AC.offlineRed).opacity(0.14))
        )
        .overlay(
            Capsule().stroke((viewModel.isStreaming ? AC.liveGreen : AC.offlineRed).opacity(0.35), lineWidth: 1)
        )
    }

    /// Enquanto transmite, mostra o último quadro realmente enviado aos alunos.
    /// Antes de transmitir, mostra a fonte selecionada, para o professor conferir
    /// se escolheu a tela certa sem precisar entrar no ar para descobrir.
    private var imagemDaPrevia: NSImage? {
        viewModel.isStreaming ? viewModel.latestPreviewImage : previewDaFonteSelecionada
    }

    private var livePreviewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11)
                .fill(AC.windowBG)

            if let preview = imagemDaPrevia {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 6) {
                    Text(viewModel.isStreaming ? "o que os alunos estão vendo" : "Pronto para transmitir")
                        .font(.system(size: 16, weight: viewModel.isStreaming ? .regular : .semibold))
                        .foregroundColor(viewModel.isStreaming ? AC.textTertiary : AC.textPrimary)
                    if let source = resolvedCaptureService.selectedSource {
                        Text("prévia de \(SourceNaming.title(source))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(AC.textTertiary)
                    }
                }
            }

            if viewModel.isStreaming {
                VStack {
                    HStack {
                        HStack(spacing: 7) {
                            if viewModel.isPaused {
                                Circle()
                                    .fill(AC.textTertiary)
                                    .frame(width: 8, height: 8)
                            } else {
                                ACPulsingDot(color: AC.stopRed, size: 8)
                            }
                            Text(viewModel.isPaused ? "PAUSADO" : "AO VIVO")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Text(resolvedCaptureService.selectedSource.map(SourceNaming.title) ?? "Fonte")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                        Spacer()
                        HStack(spacing: 4) {
                            Text("\(resolvedCaptureService.resolution.rawValue) · \(resolvedCaptureService.frameRate) fps ·")
                            if let startedAt = viewModel.streamStartedAt {
                                Text(startedAt, style: .timer)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.85))
                .padding(12)
            }
        }
        // Teto de altura para a prévia não engolir a grade de fontes em janelas menores;
        // sem layoutPriority, a prévia cede espaço primeiro quando a janela encolhe.
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 430)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(AC.border, lineWidth: 1))
    }

    /// A transmissão caiu sozinha — o professor precisa ver isso, não descobrir pelos alunos.
    private func streamErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AC.stopRed)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.needsScreenRecordingPermission
                     ? "Falta a autorização do macOS"
                     : "A transmissão foi interrompida")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AC.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(AC.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Quando falta autorização, o banner deixa de ser só aviso e vira o caminho:
            // são exatamente as duas saídas possíveis, sem competir com o aviso do macOS.
            if viewModel.needsScreenRecordingPermission {
                Button("Abrir Ajustes") {
                    ScreenRecordingPermissionService.openSystemSettings()
                }
                .buttonStyle(.acOutline(height: 26, cornerRadius: 7, fontSize: 12, horizontalPadding: 10))

                Button("Reabrir o AulaCast") {
                    ScreenRecordingPermissionService.relaunch()
                }
                .buttonStyle(.acFilled(AC.accent, height: 26, cornerRadius: 7, fontSize: 12, horizontalPadding: 10))
            } else {
                Button("Dispensar") {
                    viewModel.streamErrorMessage = nil
                }
                .buttonStyle(.acOutline(height: 26, cornerRadius: 7, fontSize: 12, horizontalPadding: 10))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(AC.stopRed.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AC.stopRed.opacity(0.35), lineWidth: 1))
    }

    private var actionButtonRow: some View {
        HStack(spacing: 12) {
            Button(action: {
                if viewModel.isStreaming {
                    viewModel.stopStream()
                } else {
                    viewModel.startStream()
                }
            }) {
                HStack(spacing: 11) {
                    Spacer()
                    Image(systemName: viewModel.isStreaming ? "stop.fill" : "play.fill")
                        .font(.system(size: 14))
                    Text(viewModel.isStreaming ? "Parar Transmissão" : "Iniciar Transmissão")
                    Spacer()
                }
            }
            .buttonStyle(.acFilled(
                viewModel.isStreaming ? AC.stopRed : AC.accent,
                height: 50,
                expands: true,
                cornerRadius: 10,
                fontSize: 18,
                horizontalPadding: 0
            ))

            Button(action: { viewModel.togglePause() }) {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.acIcon(size: 50, cornerRadius: 10, fontSize: 17))
            .disabled(!viewModel.isStreaming)
            .opacity(viewModel.isStreaming ? 1 : 0.4)
            .help(viewModel.isPaused ? "Retomar transmissão" : "Pausar transmissão")

            Button(action: { showQualitySettings.toggle() }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.acIcon(size: 50, cornerRadius: 10, fontSize: 17))
            .help("Configurações da transmissão")
            // Popover ancorado na engrenagem: fecha clicando fora ou com Esc. Como cada
            // ajuste já vale na hora, não há nada a confirmar com um botão.
            .popover(isPresented: $showQualitySettings, arrowEdge: .bottom) {
                QualitySettingsView(viewModel: viewModel, captureService: resolvedCaptureService)
            }
        }
    }

    private var addressCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Endereço dos alunos na rede local")
                    .font(.system(size: 12))
                    .foregroundColor(AC.textSecondary)
                Text(viewModel.serverURLString)
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    .foregroundColor(AC.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.serverURLString, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.acIcon(size: 34, cornerRadius: 8))
            .help("Copiar link")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(AC.cardBG))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AC.border, lineWidth: 1))
    }

    /// Serviço de captura concreto, para os componentes que precisam observá-lo.
    ///
    /// O `??` daqui criava um `ScreenCaptureService` **novo a cada leitura** quando o modelo
    /// carregava outra implementação — e esta propriedade é lida várias vezes por avaliação
    /// do `body`. Cada leitura devolvia um objeto diferente, então o `@ObservedObject` do
    /// seletor de fontes nunca observava o mesmo lugar duas vezes: a lista não atualizava e a
    /// seleção não se mantinha, além de ficar registrando serviços de captura à toa.
    /// Uma única instância de reserva mantém a identidade estável.
    private static let capturaDeReserva = ScreenCaptureService()

    private var resolvedCaptureService: ScreenCaptureService {
        (viewModel.captureService as? ScreenCaptureService) ?? Self.capturaDeReserva
    }

    /// Muda quando a fonte é trocada ou quando a transmissão começa/termina — os dois
    /// casos exigem reiniciar (ou encerrar) a atualização da prévia.
    private var chavePrevia: String {
        "\(viewModel.isStreaming)-\(resolvedCaptureService.selectedSource?.id ?? "nenhuma")"
    }

    /// Atualiza a prévia da fonte a cada segundo enquanto a transmissão está parada.
    /// Durante a transmissão isso não roda: ali a prévia vem dos quadros reais enviados
    /// aos alunos, que é a informação que de fato importa.
    private func manterPreviaDaFonteAtualizada() async {
        guard !viewModel.isStreaming else {
            previewDaFonteSelecionada = nil
            return
        }

        let provider = SourceThumbnailProvider()

        while !Task.isCancelled && !viewModel.isStreaming {
            guard let fonte = resolvedCaptureService.selectedSource else {
                previewDaFonteSelecionada = nil
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            // A captura é feita fora da MainActor para não travar a interface.
            let transporte = await Task.detached(priority: .utility) {
                ImagemCapturada(imagem: provider.thumbnail(for: fonte))
            }.value

            if Task.isCancelled { return }
            previewDaFonteSelecionada = transporte.imagem

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
