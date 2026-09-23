import SwiftUI

/// Painel de chat do professor (SRP), no desenho do chat do Meet: o controle de quem pode
/// escrever no topo, um aviso de privacidade, a mensagem fixada para a turma, mensagens sem
/// balões (nome, hora e texto) e o campo de mensagem em pílula embaixo.
public struct ChatPanelView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var chatManager: ChatManagerService
    @State private var messageText: String = ""
    /// Mensagem sob o ponteiro: só ela mostra o botão de fixar, como as ações do Meet que
    /// aparecem ao passar o mouse, para não encher o chat de botões.
    @State private var mensagemSobOMouse: String?

    public init(viewModel: MainViewModel) {
        self.viewModel = viewModel
        self._chatManager = ObservedObject(wrappedValue: viewModel.chatManager)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No Meet, "Permitir que todos enviem mensagens" fica no topo do chat — é onde
            // o professor procura quando quer silenciar a conversa. Antes ficava escondido
            // no popover de qualidade.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alunos podem escrever")
                        .m3(.titleSmall)
                        .foregroundColor(M3.onSurface)
                    Text(viewModel.isChatEnabled ? "O campo de mensagem aparece para a turma" : "O campo fica inativo na tela dos alunos")
                        .m3(.bodySmall)
                        .foregroundColor(M3.onSurfaceVariant)
                }
                Spacer()
                Toggle("", isOn: $viewModel.isChatEnabled)
                    .toggleStyle(.switch)
                    .tint(M3.primary)
                    .labelsHidden()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            // Segundo toggle, independente do de cima: só faz sentido com o chat ligado —
            // desligado, não há mensagem de aluno nenhuma para circular entre colegas.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alunos veem as mensagens uns dos outros")
                        .m3(.titleSmall)
                        .foregroundColor(M3.onSurface)
                    Text(viewModel.isStudentChatVisibleToClass
                        ? "As mensagens dos alunos vão para toda a turma, além de você"
                        : "As mensagens dos alunos chegam só para você, como hoje")
                        .m3(.bodySmall)
                        .foregroundColor(M3.onSurfaceVariant)
                }
                Spacer()
                Toggle("", isOn: $viewModel.isStudentChatVisibleToClass)
                    .toggleStyle(.switch)
                    .tint(M3.primary)
                    .labelsHidden()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .disabled(!viewModel.isChatEnabled)

            // Quem vê o quê, dito uma vez, como o aviso cinza no topo do chat do Meet.
            HStack(alignment: .top, spacing: 10) {
                M3Icone(nome: "info", tamanho: 18)
                Text(viewModel.isStudentChatVisibleToClass
                    ? "Suas mensagens vão para toda a turma. As dos alunos também."
                    : "Suas mensagens vão para toda a turma. As dos alunos chegam só para você.")
                    .m3(.bodySmall)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(M3.onSurfaceVariant)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .m3Superficie(M3.surfaceContainer, canto: M3.Canto.medio)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if let fixada = chatManager.pinnedMessage {
                cartaoDaFixada(fixada)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if chatManager.messages.isEmpty {
                VStack(spacing: 10) {
                    M3Icone(nome: "forum", tamanho: 40)
                        .foregroundColor(M3.onSurfaceVariant)
                    Text("Nenhuma mensagem ainda")
                        .m3(.titleMedium)
                        .foregroundColor(M3.onSurface)
                    Text("As perguntas dos alunos aparecem aqui.")
                        .m3(.bodyMedium)
                        .foregroundColor(M3.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(chatManager.messages) { msg in
                                mensagem(msg).id(msg.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: chatManager.messages.count) { _ in
                        if let ultima = chatManager.messages.last {
                            withAnimation(M3.Mola.padrao) { proxy.scrollTo(ultima.id, anchor: .bottom) }
                        }
                    }
                    // Ao abrir o painel, já na mensagem mais recente.
                    .onAppear {
                        if let ultima = chatManager.messages.last {
                            proxy.scrollTo(ultima.id, anchor: .bottom)
                        }
                    }
                }
            }

            campoDeMensagem
        }
        .animation(M3.Mola.padrao, value: chatManager.pinnedMessage?.id)
    }

    /// A fixada, como a turma a vê no topo do chat dela: um cartão tonal pequeno, com o
    /// texto em até duas linhas (o texto inteiro fica na dica) e o botão de desafixar.
    private func cartaoDaFixada(_ fixada: ChatMessage) -> some View {
        HStack(spacing: 10) {
            M3Icone(nome: "push_pin", tamanho: 18, preenchido: true)
            Text(fixada.text)
                .m3(.bodyMedium)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(fixada.text)
                .accessibilityLabel("Fixada para a turma: \(fixada.text)")
            M3BotaoDeIcone(icone: "keep_off", variante: .padrao, tamanho: 32, ajuda: "Desafixar") {
                viewModel.unpinMessage()
            }
        }
        .foregroundColor(M3.onSecondaryContainer)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .m3Superficie(M3.secondaryContainer, canto: M3.Canto.medio)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func mensagem(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(msg.isProf ? "Você" : msg.sender)
                    .m3(.titleSmall)
                    .foregroundColor(msg.isProf ? M3.primary : M3.onSurface)
                Text(msg.timestamp, style: .time)
                    .m3(.labelMedium)
                    .foregroundColor(M3.onSurfaceVariant)
                if estaFixada(msg) {
                    M3Icone(nome: "push_pin", tamanho: 14, preenchido: true)
                        .foregroundColor(M3.onSurfaceVariant)
                        .help("Fixada para a turma")
                }
            }
            Text(msg.text)
                .m3(.bodyMedium)
                .foregroundColor(M3.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Por cima do cabeçalho (nome e hora, sempre curto), para o botão aparecer e sumir
        // sem empurrar o texto. Só nas mensagens do professor: as dos alunos são privadas e
        // não podem ir para a tela da turma.
        .overlay(alignment: .topTrailing) {
            if msg.isProf, mensagemSobOMouse == msg.id {
                let fixada = estaFixada(msg)
                M3BotaoDeIcone(
                    icone: fixada ? "keep_off" : "keep",
                    variante: .padrao,
                    tamanho: 32,
                    ajuda: fixada ? "Desafixar" : "Fixar para a turma"
                ) {
                    if fixada { viewModel.unpinMessage() } else { viewModel.pinMessage(msg) }
                }
                .offset(y: -6)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { dentro in
            guard msg.isProf else { return }
            if dentro {
                mensagemSobOMouse = msg.id
            } else if mensagemSobOMouse == msg.id {
                mensagemSobOMouse = nil
            }
        }
        .animation(M3.Mola.efeito, value: mensagemSobOMouse == msg.id)
    }

    private func estaFixada(_ msg: ChatMessage) -> Bool {
        chatManager.pinnedMessage?.id == msg.id
    }

    private var campoDeMensagem: some View {
        HStack(spacing: 8) {
            TextField("Mensagem para toda a turma", text: $messageText)
                .textFieldStyle(.plain)
                .m3(.bodyLarge)
                .foregroundColor(M3.onSurface)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .onSubmit { sendMessage() }
            M3BotaoDeIcone(
                icone: "chevron_right",
                variante: temTexto ? .preenchido : .padrao,
                tamanho: 40,
                ajuda: "Enviar"
            ) { sendMessage() }
            .disabled(!temTexto)
            .padding(.trailing, 4)
        }
        .background(Capsule(style: .continuous).fill(M3.surfaceContainerHigh))
        .padding(16)
        .animation(M3.Mola.efeito, value: temTexto)
    }

    private var temTexto: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        guard temTexto else { return }
        viewModel.sendProfMessage(text: messageText)
        messageText = ""
    }
}
