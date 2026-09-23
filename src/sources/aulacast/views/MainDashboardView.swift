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

    /// Painel lateral (alunos, chat, arquivos) aberto ou fechado, lembrado entre aberturas.
    @AppStorage("aulacast.painelAberto") private var painelAberto = true
    @AppStorage("aulacast.abaDoPainel") private var abaSalva = AbaDoPainel.alunos.rawValue

    /// Quantas mensagens de alunos o professor já teve à vista (o resto é "não lida").
    @State private var mensagensVistas = 0
    @State private var enderecoCopiado = false

    /// Prévia da fonte escolhida enquanto a transmissão ainda não começou.
    @State private var previewDaFonteSelecionada: NSImage?

    public init() {}

    public var body: some View {
        dashboardContent
        // Reinicia a atualização quando a fonte muda ou quando a transmissão começa/para.
        .task(id: chavePrevia) {
            await manterPreviaDaFonteAtualizada()
        }
        .onChange(of: viewModel.studentMessagesReceived) { total in
            if chatVisivel { mensagensVistas = total }
        }
        .onChange(of: chatVisivel) { visivel in
            if visivel { mensagensVistas = viewModel.studentMessagesReceived }
        }
    }

    private var aba: Binding<AbaDoPainel> {
        Binding(
            get: { AbaDoPainel(rawValue: abaSalva) ?? .alunos },
            set: { abaSalva = $0.rawValue }
        )
    }

    private var chatVisivel: Bool { painelAberto && aba.wrappedValue == .chat }

    private var naoLidas: Int { max(0, viewModel.studentMessagesReceived - mensagensVistas) }

    /// Barra superior (estado da aula, endereço, botão do painel) + área principal
    /// (prévia, controles, fontes) + painel lateral que abre e fecha.
    private var dashboardContent: some View {
        VStack(spacing: 0) {
            barraSuperior
            Divider()

            HStack(spacing: 0) {
                areaPrincipal

                if painelAberto {
                    Divider()
                    ClassInspectorView(
                        viewModel: viewModel,
                        clientManager: viewModel.clientManager,
                        aba: aba,
                        naoLidas: naoLidas
                    )
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        // A barra ocupa a faixa dos botões de fechar/minimizar, como a barra de
        // ferramentas dos apps do Mac, em vez de deixar uma tira vazia acima dela.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: painelAberto ? 1000 : 700, minHeight: 640)
        .background(AC.windowBG)
        .animation(.easeInOut(duration: 0.2), value: painelAberto)
    }

    private var areaPrincipal: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = viewModel.streamErrorMessage {
                streamErrorBanner(error)
            }
            livePreviewCard
            barraDeControles
            SourcePickerView(recorder: resolvedCaptureService)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AC.windowBG)
    }

    // MARK: - Barra superior

    /// Segue a barra de ferramentas do Mac: identidade e estado à esquerda, o que precisa
    /// ficar sempre à mão à direita, e o botão do painel ancorado na ponta direita, para
    /// não virar alvo que muda de lugar (Apple HIG).
    private var barraSuperior: some View {
        HStack(spacing: 12) {
            ACBrandMark(tamanho: 22)
            statusDaAula
            Spacer(minLength: 16)
            enderecoDaTurma
            botaoDoPainel
        }
        // Espaço para os botões de fechar/minimizar/ampliar da janela.
        .padding(.leading, 82)
        .padding(.trailing, 12)
        .frame(height: 34)
        .padding(.top, 2)
        .background(AC.panelBG)
    }

    private enum EstadoDaAula { case aoVivo, pausada, interrompida, foraDoAr }

    private var estadoDaAula: EstadoDaAula {
        if viewModel.isStreaming { return viewModel.isPaused ? .pausada : .aoVivo }
        return viewModel.isSessionOpen ? .interrompida : .foraDoAr
    }

    private var statusDaAula: some View {
        let cor: Color
        let texto: String
        switch estadoDaAula {
        case .aoVivo: cor = AC.liveGreen; texto = "Ao vivo"
        case .pausada: cor = AC.pausedAmber; texto = "Pausada"
        case .interrompida: cor = AC.stopRed; texto = "Transmissão interrompida"
        case .foraDoAr: cor = AC.textTertiary; texto = "Fora do ar"
        }
        return HStack(spacing: 7) {
            if estadoDaAula == .aoVivo {
                ACPulsingDot(color: cor, size: 8)
            } else {
                Circle().fill(cor).frame(width: 8, height: 8)
            }
            Text(texto)
                .font(.system(size: 12, weight: .semibold))
            if let inicio = viewModel.streamStartedAt, viewModel.isStreaming {
                Text("·").foregroundColor(AC.textTertiary)
                Text(inicio, style: .timer)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(AC.textSecondary)
            }
        }
        .foregroundColor(estadoDaAula == .foraDoAr ? AC.textSecondary : cor)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(cor.opacity(0.13)))
        .help(estadoDaAula == .aoVivo ? "A turma está vendo a sua tela. O tempo é desde o início da transmissão." : "")
    }

    /// Endereço que a turma digita. Na barra superior, e não num cartão grande: fica sempre
    /// à vista (é o que o professor mais repete no começo da aula) sem tirar espaço da prévia.
    private var enderecoDaTurma: some View {
        HStack(spacing: 8) {
            Text("Turma:")
                .font(.system(size: 12))
                .foregroundColor(AC.textSecondary)
            Text(viewModel.displayAddress)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(AC.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
            Button(action: copiarEndereco) {
                Image(systemName: enderecoCopiado ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(enderecoCopiado ? AC.liveGreen : AC.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(enderecoCopiado ? "Link copiado" : "Copiar o link (com http://, para colar num grupo ou documento)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(AC.inputBG))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AC.border, lineWidth: 1))
    }

    private func copiarEndereco() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.serverURLString, forType: .string)
        enderecoCopiado = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { enderecoCopiado = false }
    }

    /// Abre e fecha o painel lateral. Com ele fechado, o contador de mensagens novas fica
    /// no próprio botão — como na página do aluno.
    private var botaoDoPainel: some View {
        Button(action: { painelAberto.toggle() }) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14))
                .foregroundColor(painelAberto ? AC.accent : AC.textSecondary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(painelAberto ? AC.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if !painelAberto && naoLidas > 0 {
                ACContador(valor: naoLidas).offset(x: 6, y: -5)
            }
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help(painelAberto ? "Esconder alunos, chat e arquivos (⌥⌘I)" : "Mostrar alunos, chat e arquivos (⌥⌘I)")
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

            // Pausada: a turma vê a imagem congelada, e a prévia mostra isso.
            if viewModel.isStreaming && viewModel.isPaused {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 8) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 24))
                        Text("Pausada: a turma vê a imagem congelada")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                }
            }
        }
        // Teto de altura para a prévia não engolir a grade de fontes em janelas menores;
        // sem layoutPriority, a prévia cede espaço primeiro quando a janela encolhe.
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 470)
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

    /// Controles logo abaixo da prévia, como a barra de controles dos apps de reunião:
    /// a ação principal (iniciar/parar) à esquerda e larga o bastante para não errar, a
    /// pausa ao lado, e à direita o que está indo para a turma e o ajuste de qualidade.
    private var barraDeControles: some View {
        HStack(spacing: 10) {
            Button(action: {
                if viewModel.isStreaming {
                    viewModel.stopStream()
                } else {
                    viewModel.startStream()
                }
            }) {
                HStack(spacing: 9) {
                    Image(systemName: viewModel.isStreaming ? "stop.fill" : "play.fill")
                        .font(.system(size: 13))
                    Text(viewModel.isStreaming ? "Parar transmissão" : "Iniciar transmissão")
                }
                .frame(minWidth: 210)
            }
            .buttonStyle(.acFilled(
                viewModel.isStreaming ? AC.stopRed : AC.accent,
                height: 40,
                cornerRadius: 9,
                fontSize: 15,
                horizontalPadding: 18
            ))
            .disabled(viewModel.isStarting)
            .opacity(viewModel.isStarting ? 0.6 : 1)

            // A captura caiu, mas a turma segue conectada: além de tentar de novo, o
            // professor precisa de um jeito de encerrar a sessão e liberar o Mac.
            if viewModel.isSessionOpen && !viewModel.isStreaming {
                Button(action: { viewModel.stopStream() }) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.acIcon(size: 40, cornerRadius: 9, fontSize: 14))
                .help("Encerrar a sessão e desconectar a turma")
            }

            Button(action: { viewModel.togglePause() }) {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.acIcon(size: 40, cornerRadius: 9, fontSize: 14))
            .disabled(!viewModel.isStreaming)
            .opacity(viewModel.isStreaming ? 1 : 0.4)
            .help(viewModel.isPaused ? "Retomar transmissão" : "Pausar transmissão (a turma vê a imagem congelada)")

            Spacer(minLength: 12)

            // O que está indo para a turma, em texto discreto — antes ficava por cima da
            // própria prévia, tampando a imagem.
            Text(resumoDaFonte)
                .font(.system(size: 12))
                .foregroundColor(AC.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: { showQualitySettings.toggle() }) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.acIcon(size: 40, cornerRadius: 9, fontSize: 14))
            .help("Qualidade da transmissão e chat")
            // Popover ancorado no botão: fecha clicando fora ou com Esc. Como cada
            // ajuste já vale na hora, não há nada a confirmar com um botão.
            .popover(isPresented: $showQualitySettings, arrowEdge: .bottom) {
                QualitySettingsView(viewModel: viewModel, captureService: resolvedCaptureService)
            }
        }
    }

    private var resumoDaFonte: String {
        let fonte = resolvedCaptureService.selectedSource.map(SourceNaming.title) ?? "Nenhuma fonte"
        return "\(fonte) · \(resolvedCaptureService.resolution.rawValue) · \(resolvedCaptureService.frameRate) fps"
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
