import SwiftUI

/// Transporta a imagem capturada entre tarefas. No macOS 13 o `NSImage` ainda não é
/// `Sendable`; aqui a instância é criada dentro da própria tarefa e entregue a um único
/// destino, sem ser compartilhada, então a travessia é segura.
private struct ImagemCapturada: @unchecked Sendable {
    let imagem: NSImage?
}

/// Janela principal do professor, no desenho de uma chamada do Google Meet em Material 3:
/// um palco com o que a turma vê, uma barra de controles embaixo e, à direita, um painel
/// que mostra uma área de cada vez (Apresentar, Alunos, Chat, Arquivos).
///
/// Barra de baixo, como no Meet: à esquerda o estado da aula e o endereço; no centro os
/// controles da aula, com a ação principal em pílula (azul para começar, vermelha para
/// encerrar, como o "sair da chamada"); à direita os botões que abrem cada painel, com
/// contadores. Clicar de novo no botão do painel aberto fecha o painel.
public struct MainDashboardView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @State private var mostrarQualidade = false

    /// Painel lateral aberto ou fechado, e qual área, lembrados entre aberturas.
    /// Na primeira abertura mostra "Apresentar": é o primeiro passo de qualquer aula.
    @AppStorage("aulacast.painelAberto") private var painelAberto = true
    @AppStorage("aulacast.abaDoPainel") private var abaSalva = AbaDoPainel.apresentar.rawValue

    /// Quantas mensagens de alunos o professor já teve à vista (o resto é "não lida").
    @State private var mensagensVistas = 0
    @State private var enderecoCopiado = false

    /// Prévia da fonte escolhida enquanto a transmissão ainda não começou.
    @State private var previewDaFonteSelecionada: NSImage?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                palco
                if painelAberto {
                    SidePanelView(
                        viewModel: viewModel,
                        clientManager: viewModel.clientManager,
                        captureService: resolvedCaptureService,
                        aba: aba.wrappedValue,
                        fechar: { painelAberto = false }
                    )
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            // Faixa dos botões de fechar/minimizar da janela, que ficam por cima.
            .padding(.top, 38)

            barraDeControles
        }
        .frame(minWidth: painelAberto ? 1040 : 760, minHeight: 620)
        .background(M3.surfaceContainerLow)
        .overlay(alignment: .topLeading) { tituloDaJanela }
        .ignoresSafeArea(.container, edges: .top)
        .animation(M3.Mola.padrao, value: painelAberto)
        .animation(M3.Mola.padrao, value: abaSalva)
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

    // MARK: - Estado do painel

    private var aba: Binding<AbaDoPainel> {
        Binding(
            get: { AbaDoPainel(rawValue: abaSalva) ?? .apresentar },
            set: { abaSalva = $0.rawValue }
        )
    }

    private var chatVisivel: Bool { painelAberto && aba.wrappedValue == .chat }

    private var naoLidas: Int { max(0, viewModel.studentMessagesReceived - mensagensVistas) }

    /// Abre a área pedida; se ela já é a que está aberta, fecha o painel (como no Meet).
    private func alternarPainel(_ destino: AbaDoPainel) {
        if painelAberto && aba.wrappedValue == destino {
            painelAberto = false
        } else {
            aba.wrappedValue = destino
            painelAberto = true
        }
    }

    // MARK: - Título na faixa da janela

    private var tituloDaJanela: some View {
        HStack(spacing: 8) {
            ACBrandMark(tamanho: 18)
            Text("AulaCast")
                .m3(.titleSmall)
                .foregroundColor(M3.onSurfaceVariant)
        }
        .padding(.leading, 84)
        .frame(height: 30)
        .padding(.top, 2)
        .allowsHitTesting(false)
    }

    // MARK: - Palco

    /// Enquanto transmite, mostra o último quadro realmente enviado aos alunos.
    /// Antes de transmitir, mostra a fonte selecionada, para o professor conferir
    /// se escolheu a tela certa sem precisar entrar no ar para descobrir.
    private var imagemDaPrevia: NSImage? {
        viewModel.isStreaming ? viewModel.latestPreviewImage : previewDaFonteSelecionada
    }

    private var palco: some View {
        VStack(spacing: 12) {
            if let erro = viewModel.streamErrorMessage {
                bannerDeErro(erro)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                // Fundo escuro nos dois modos: é onde fica a imagem, como o palco do Meet.
                Color(hex: 0x0E0E0E)

                if let preview = imagemDaPrevia {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    palcoVazio
                }

                if viewModel.isStreaming && viewModel.isPaused {
                    ZStack {
                        Color.black.opacity(0.55)
                        VStack(spacing: 12) {
                            M3Icone(nome: "pause_circle", tamanho: 48, preenchido: true)
                            Text("Pausada")
                                .m3(.titleLarge)
                            Text("A turma vê a imagem congelada")
                                .m3(.bodyMedium)
                                .opacity(0.8)
                        }
                        .foregroundColor(.white)
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: M3.Canto.extraGrande, style: .continuous))
            .animation(M3.Mola.efeito, value: viewModel.isPaused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(M3.Mola.padrao, value: viewModel.streamErrorMessage)
    }

    /// Nada para mostrar ainda: diz o que fazer e dá o caminho direto (guia de estados
    /// vazios do NN/g: situação, próximo passo, ação).
    private var palcoVazio: some View {
        VStack(spacing: 14) {
            M3Icone(nome: "present_to_all", tamanho: 48)
                .foregroundColor(Color(white: 0.75))
            Text(viewModel.isStreaming ? "Preparando a imagem…" : "Escolha o que a turma vai ver")
                .m3(.titleLarge)
                .foregroundColor(.white)
            if !viewModel.isStreaming {
                M3Botao(titulo: "Apresentar", icone: "present_to_all", variante: .tonal) {
                    aba.wrappedValue = .apresentar
                    painelAberto = true
                }
            }
        }
    }

    /// A transmissão caiu sozinha, ou falta autorização: o professor precisa ver isso,
    /// não descobrir pelos alunos. É um "banner" do Material: aviso e as saídas possíveis.
    private func bannerDeErro(_ mensagem: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            M3Icone(nome: "error", tamanho: 24, preenchido: true)
                .foregroundColor(M3.onErrorContainer)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.needsScreenRecordingPermission
                     ? "Falta a autorização do macOS"
                     : "A transmissão foi interrompida")
                    .m3(.titleSmall)
                Text(mensagem)
                    .m3(.bodyMedium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(M3.onErrorContainer)

            Spacer(minLength: 8)

            // Quando falta autorização, o banner deixa de ser só aviso e vira o caminho:
            // são exatamente as duas saídas possíveis, sem competir com o aviso do macOS.
            if viewModel.needsScreenRecordingPermission {
                M3Botao(titulo: "Abrir Ajustes", variante: .texto) {
                    ScreenRecordingPermissionService.openSystemSettings()
                }
                M3Botao(titulo: "Reabrir o AulaCast", variante: .preenchido) {
                    ScreenRecordingPermissionService.relaunch()
                }
            } else {
                M3Botao(titulo: "Dispensar", variante: .texto) {
                    viewModel.streamErrorMessage = nil
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .m3Superficie(M3.errorContainer, canto: M3.Canto.grande)
    }

    // MARK: - Barra de controles (embaixo)

    private var barraDeControles: some View {
        // Três seções lado a lado, com as laterais de largura igual e flexível: assim os
        // controles ficam no meio quando há espaço e, na janela estreita, o endereço
        // encolhe com reticências em vez de ficar por baixo dos botões (era um ZStack, e
        // na largura padrão o ícone de copiar invadia o botão de apresentar).
        HStack(spacing: 16) {
            estadoEEndereco
                .frame(maxWidth: .infinity, alignment: .leading)
            controlesDaAula
                .fixedSize()
            botoesDosPaineis
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 88)
    }

    // Esquerda: estado da aula e o endereço que a turma digita.
    /// O endereço nunca é cortado: é o que o professor dita para a turma. Faltando espaço,
    /// quem cede é o rótulo do estado ("Ao vivo"), e fica o ponto colorido com o tempo.
    private var estadoEEndereco: some View {
        ViewThatFits(in: .horizontal) {
            estadoEEnderecoCompleto(compacto: false)
            estadoEEnderecoCompleto(compacto: true)
        }
    }

    private func estadoEEnderecoCompleto(compacto: Bool) -> some View {
        HStack(spacing: 14) {
            chipDeEstado(compacto: compacto)
                .fixedSize()

            Rectangle()
                .fill(M3.outlineVariant)
                .frame(width: 1, height: 20)

            HStack(spacing: 4) {
                Text(viewModel.displayAddress)
                    .font(M3Tipo.fonte(tamanho: 15, peso: 500).monospacedDigit())
                    .foregroundColor(M3.onSurface)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize()
                M3BotaoDeIcone(
                    icone: enderecoCopiado ? "check" : "content_copy",
                    variante: .padrao,
                    tamanho: 36,
                    ajuda: enderecoCopiado ? "Link copiado" : "Copiar o link da turma"
                ) { copiarEndereco() }
            }
        }
    }

    private enum EstadoDaAula { case aoVivo, pausada, interrompida, foraDoAr }

    private var estadoDaAula: EstadoDaAula {
        if viewModel.isStreaming { return viewModel.isPaused ? .pausada : .aoVivo }
        return viewModel.isSessionOpen ? .interrompida : .foraDoAr
    }

    private func chipDeEstado(compacto: Bool) -> some View {
        let (fundo, frente, texto): (Color, Color, String) = {
            switch estadoDaAula {
            case .aoVivo: return (M3.tertiaryContainer, M3.onTertiaryContainer, "Ao vivo")
            case .pausada: return (M3.warningContainer, M3.onWarningContainer, "Pausada")
            case .interrompida: return (M3.errorContainer, M3.onErrorContainer, "Interrompida")
            case .foraDoAr: return (M3.surfaceContainerHighest, M3.onSurfaceVariant, "Fora do ar")
            }
        }()
        return HStack(spacing: 8) {
            if estadoDaAula == .aoVivo {
                ACPulsingDot(color: M3.tertiary, size: 8)
            } else {
                Circle().fill(frente.opacity(0.7)).frame(width: 8, height: 8)
            }
            if !compacto {
                Text(texto).m3(.labelLarge)
            }
            if let inicio = viewModel.streamStartedAt, viewModel.isStreaming {
                Text(inicio, style: .timer)
                    .font(M3Tipo.fonte(tamanho: 14, peso: 500).monospacedDigit())
                    .opacity(0.8)
            }
        }
        .foregroundColor(frente)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule(style: .continuous).fill(fundo))
        .help(texto)
        .animation(M3.Mola.efeito, value: estadoDaAula == .aoVivo)
    }

    private func copiarEndereco() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.serverURLString, forType: .string)
        enderecoCopiado = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { enderecoCopiado = false }
    }

    // Centro: apresentar, pausar, qualidade e a ação principal.
    private var controlesDaAula: some View {
        HStack(spacing: 12) {
            M3BotaoDeIcone(
                icone: "present_to_all",
                selecionado: painelAberto && aba.wrappedValue == .apresentar,
                ajuda: "Escolher o que a turma vê"
            ) { alternarPainel(.apresentar) }

            M3BotaoDeIcone(
                icone: viewModel.isPaused ? "play_arrow" : "pause",
                selecionado: viewModel.isPaused,
                ajuda: viewModel.isPaused ? "Retomar a transmissão" : "Pausar (a turma vê a imagem congelada)"
            ) { viewModel.togglePause() }
            .disabled(!viewModel.isStreaming)

            M3BotaoDeIcone(icone: "tune", selecionado: mostrarQualidade, ajuda: "Qualidade da transmissão") {
                mostrarQualidade.toggle()
            }
            // Popover ancorado no botão: fecha clicando fora ou com Esc. Cada ajuste já
            // vale na hora, então não há nada a confirmar.
            .popover(isPresented: $mostrarQualidade, arrowEdge: .top) {
                QualitySettingsView(viewModel: viewModel, captureService: resolvedCaptureService)
            }

            // A captura caiu, mas a turma segue conectada: além de tentar de novo, o
            // professor precisa de um jeito de encerrar a sessão e liberar o Mac.
            if viewModel.isSessionOpen && !viewModel.isStreaming {
                M3BotaoDeIcone(icone: "stop", variante: .perigo, ajuda: "Encerrar a sessão e desconectar a turma") {
                    viewModel.stopStream()
                }
            }

            if viewModel.isStreaming {
                M3Botao(titulo: "Encerrar", icone: "stop", variante: .perigo, altura: 48, larguraMinima: 140) {
                    viewModel.stopStream()
                }
                .help("Parar a transmissão")
            } else {
                M3Botao(titulo: "Iniciar transmissão", icone: "play_arrow", variante: .preenchido, altura: 48) {
                    viewModel.startStream()
                }
                .disabled(viewModel.isStarting)
            }
        }
        .animation(M3.Mola.padrao, value: viewModel.isStreaming)
    }

    private var maos: Int { viewModel.clientManager.handRaisedCount }

    // Direita: um botão por painel, com contadores.
    private var botoesDosPaineis: some View {
        HStack(spacing: 8) {
            // Com mão levantada, o selo do botão troca o total de alunos pelo número de mãos,
            // em âmbar: é o que pede o professor agora. Sem mãos, volta a ser a contagem neutra.
            M3BotaoDeIcone(
                icone: "group",
                variante: .padrao,
                selecionado: painelAberto && aba.wrappedValue == .alunos,
                contador: maos > 0 ? maos : viewModel.clientManager.identifiedClients.count,
                contadorNeutro: maos == 0,
                contadorDeAtencao: maos > 0,
                ajuda: maos == 0 ? "Alunos" : maos == 1 ? "Alunos — 1 mão levantada" : "Alunos — \(maos) mãos levantadas"
            ) { alternarPainel(.alunos) }

            M3BotaoDeIcone(
                icone: "chat",
                variante: .padrao,
                selecionado: chatVisivel,
                contador: naoLidas,
                ajuda: naoLidas > 0 ? "Chat — \(naoLidas) mensagem(ns) nova(s)" : "Chat"
            ) { alternarPainel(.chat) }

            M3BotaoDeIcone(
                icone: "attach_file",
                variante: .padrao,
                selecionado: painelAberto && aba.wrappedValue == .arquivos,
                contador: viewModel.sharedFiles.count,
                contadorNeutro: true,
                ajuda: "Arquivos da aula"
            ) { alternarPainel(.arquivos) }
        }
        // ⌥⌘I, o atalho de "Mostrar Inspetor" dos apps da Apple, abre e fecha o painel.
        .background(
            Button("") { painelAberto.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .opacity(0)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Captura

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
