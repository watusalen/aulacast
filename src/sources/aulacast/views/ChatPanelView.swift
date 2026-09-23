import SwiftUI

/// Painel de chat do professor (SRP), no desenho do chat do Meet: o controle de quem pode
/// escrever no topo, um aviso de privacidade, mensagens sem balões (nome, hora e texto) e
/// o campo de mensagem em pílula embaixo.
public struct ChatPanelView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var chatManager: ChatManagerService
    @State private var messageText: String = ""

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

            // Quem vê o quê, dito uma vez, como o aviso cinza no topo do chat do Meet.
            HStack(alignment: .top, spacing: 10) {
                M3Icone(nome: "info", tamanho: 18)
                Text("Suas mensagens vão para toda a turma. As dos alunos chegam só para você.")
                    .m3(.bodySmall)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(M3.onSurfaceVariant)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .m3Superficie(M3.surfaceContainer, canto: M3.Canto.medio)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

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
            }
            Text(msg.text)
                .m3(.bodyMedium)
                .foregroundColor(M3.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
