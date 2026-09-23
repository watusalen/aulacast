import SwiftUI

/// As áreas do painel lateral do professor.
public enum AbaDoPainel: String, CaseIterable, Identifiable {
    case apresentar, alunos, chat, arquivos

    public var id: String { rawValue }

    var titulo: String {
        switch self {
        case .apresentar: return "Apresentar"
        case .alunos: return "Alunos"
        case .chat: return "Chat da aula"
        case .arquivos: return "Arquivos"
        }
    }
}

/// Painel lateral do professor: um cartão de cantos grandes com uma área de cada vez,
/// título e botão de fechar — o desenho dos painéis de Pessoas e Chat do Google Meet.
///
/// Uma área por vez dá a cada uma a altura inteira. Antes eram painéis empilhados, e a
/// lista cortava e o chat mal mostrava três mensagens.
struct SidePanelView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var clientManager: ClientManagerService
    @ObservedObject var captureService: ScreenCaptureService
    let aba: AbaDoPainel
    let fechar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(aba.titulo)
                    .m3(.titleLarge)
                    .foregroundColor(M3.onSurface)
                Spacer()
                M3BotaoDeIcone(icone: "close", variante: .padrao, tamanho: 40, ajuda: "Fechar o painel (⌥⌘I)", acao: fechar)
            }
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Group {
                switch aba {
                case .apresentar:
                    SourcePickerView(recorder: captureService)
                case .alunos:
                    StudentListView(clientManager: clientManager, viewModel: viewModel)
                case .chat:
                    ChatPanelView(viewModel: viewModel)
                case .arquivos:
                    SharedFilesPanelView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
        .m3Superficie(M3.surface, canto: M3.Canto.extraGrande)
        .id(aba)
    }
}
