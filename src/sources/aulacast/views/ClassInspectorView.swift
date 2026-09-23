import SwiftUI

/// As três áreas do painel lateral do professor.
public enum AbaDoPainel: String, CaseIterable, Identifiable {
    case alunos, chat, arquivos

    public var id: String { rawValue }

    var titulo: String {
        switch self {
        case .alunos: return "Alunos"
        case .chat: return "Chat"
        case .arquivos: return "Arquivos"
        }
    }

    var icone: String {
        switch self {
        case .alunos: return "person.2"
        case .chat: return "bubble.left.and.bubble.right"
        case .arquivos: return "doc.on.doc"
        }
    }
}

/// Painel lateral do professor: alunos, chat e arquivos, uma área de cada vez.
///
/// Antes eram três painéis empilhados, cada um com um terço da altura: a lista de alunos
/// cortava, o chat mal mostrava três mensagens, e os estados vazios ocupavam metade da
/// coluna. Uma área por vez, escolhida por abas, segue o que os apps de reunião fazem com
/// o painel do anfitrião (pessoas, chat, atividades) e dá a cada uma a altura inteira.
struct ClassInspectorView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var clientManager: ClientManagerService
    @Binding var aba: AbaDoPainel
    /// Mensagens de alunos que chegaram com o chat fora de vista.
    let naoLidas: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(AbaDoPainel.allCases) { item in
                    botaoDaAba(item)
                }
            }
            .padding(8)

            Divider()

            Group {
                switch aba {
                case .alunos:
                    StudentListView(clientManager: clientManager, serverURLString: viewModel.serverURLString)
                case .chat:
                    ChatPanelView(viewModel: viewModel)
                case .arquivos:
                    SharedFilesPanelView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AC.panelBG)
    }

    private func botaoDaAba(_ item: AbaDoPainel) -> some View {
        let selecionada = aba == item
        return Button(action: { aba = item }) {
            HStack(spacing: 6) {
                Image(systemName: item.icone)
                    .font(.system(size: 12))
                Text(item.titulo)
                    .font(.system(size: 13, weight: selecionada ? .semibold : .regular))
                if let contagem = contagem(de: item) {
                    Text("\(contagem)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(selecionada ? AC.accent : AC.textTertiary)
                }
                if item == .chat && naoLidas > 0 {
                    ACContador(valor: naoLidas)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .foregroundColor(selecionada ? AC.accent : AC.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selecionada ? AC.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ajuda(de: item))
    }

    /// Quantos itens há na área (alunos identificados, arquivos). O chat usa o contador
    /// de não lidas, e não um total.
    private func contagem(de item: AbaDoPainel) -> Int? {
        switch item {
        case .alunos: return clientManager.identifiedClients.count
        case .arquivos: return viewModel.sharedFiles.count
        case .chat: return nil
        }
    }

    private func ajuda(de item: AbaDoPainel) -> String {
        switch item {
        case .alunos: return "Quem está na aula e quem está com ela à vista"
        case .chat: return naoLidas > 0 ? "\(naoLidas) mensagem(ns) nova(s) dos alunos" : "Conversa com a turma"
        case .arquivos: return "Arquivos que a turma pode baixar"
        }
    }
}

/// Contador vermelho de novidades (o mesmo da página do aluno).
struct ACContador: View {
    let valor: Int

    var body: some View {
        Text(valor > 9 ? "9+" : "\(valor)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 17, minHeight: 17)
            .background(Capsule().fill(AC.stopRed))
    }
}
