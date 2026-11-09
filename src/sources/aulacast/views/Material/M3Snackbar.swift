import SwiftUI
import AppKit

/// Snackbar do Material 3, não modal, no pé da janela: só o texto, centralizado, sem botão.
/// Usado para avisar que a lista de presença foi salva (RF-21).
///
/// Com o mouse em cima ela não some: o tempo só corre fora dela. Quando há arquivo, a
/// superfície inteira é o clique que o mostra no Finder (por isso o cursor vira mãozinha e
/// há camada de estado); o aviso de erro, sem arquivo, não é clicável.
struct M3Snackbar: View {
    @ObservedObject var viewModel: MainViewModel
    /// Segundos até sumir sozinho, contados do aparecimento.
    var duracao: TimeInterval = 8
    /// Segundos até sumir depois que o mouse sai de cima.
    var duracaoAposSair: TimeInterval = 3

    @State private var mouseSobre = false

    /// Muda quando o aviso troca ou o mouse entra/sai: reinicia a contagem.
    private struct Contagem: Equatable {
        let aviso: MainViewModel.AvisoDaChamada?
        let sobre: Bool
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let aviso = viewModel.avisoDaChamada {
                balao(aviso)
                    .onDisappear {
                        // Sumiu com o mouse em cima (clique ou fim do tempo): devolve o cursor.
                        if mouseSobre && aviso.arquivo != nil { NSCursor.pop() }
                        mouseSobre = false
                    }
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: Contagem(aviso: aviso, sobre: mouseSobre)) {
                        // O mouse em cima segura o aviso; ao sair, ele some em instantes.
                        if mouseSobre { return }
                        let espera = jaPassouOMouse ? duracaoAposSair : duracao
                        try? await Task.sleep(nanoseconds: UInt64(espera * 1_000_000_000))
                        if !Task.isCancelled { viewModel.avisoDaChamada = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(M3.Mola.padrao, value: viewModel.avisoDaChamada)
        .allowsHitTesting(viewModel.avisoDaChamada != nil)
        .onChange(of: viewModel.avisoDaChamada) { _ in
            mouseSobre = false
            jaPassouOMouse = false
        }
    }

    /// O mouse já esteve em cima deste aviso (depois disso a contagem é a curta).
    @State private var jaPassouOMouse = false

    @ViewBuilder
    private func balao(_ aviso: MainViewModel.AvisoDaChamada) -> some View {
        let conteudo = Text(aviso.texto)
            .m3(.bodyMedium)
            .multilineTextAlignment(.center)
            .foregroundColor(M3.inverseOnSurface)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minWidth: 344, maxWidth: 672, minHeight: 48)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: M3.Canto.extraPequeno, style: .continuous)
                    .fill(M3.inverseSurface)
            )
            // Camada de estado do hover, só quando o aviso leva ao arquivo.
            .overlay {
                if aviso.arquivo != nil && mouseSobre {
                    RoundedRectangle(cornerRadius: M3.Canto.extraPequeno, style: .continuous)
                        .fill(M3.inverseOnSurface.opacity(0.08))
                        .allowsHitTesting(false)
                }
            }
            // Elevação nível 3 do M3: duas sombras.
            .shadow(color: .black.opacity(0.30), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 4)
            .contentShape(Rectangle())
            .onHover { sobre in
                mouseSobre = sobre
                if sobre { jaPassouOMouse = true }
                guard aviso.arquivo != nil else { return }
                if sobre { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

        if let arquivo = aviso.arquivo {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([arquivo])
                viewModel.avisoDaChamada = nil
            } label: { conteudo }
            .buttonStyle(.plain)
            .accessibilityHint("Mostra o arquivo no Finder")
        } else {
            conteudo
                .accessibilityElement(children: .combine)
        }
    }
}
