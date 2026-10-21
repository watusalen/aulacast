import SwiftUI
import AppKit

/// Snackbar do Material 3, não modal, no pé da janela: texto, uma ação opcional e fechamento
/// automático. Usado para avisar que a chamada foi salva (RF-21).
struct M3Snackbar: View {
    @ObservedObject var viewModel: MainViewModel
    /// Segundos até sumir sozinho.
    var duracao: TimeInterval = 8

    var body: some View {
        ZStack(alignment: .bottom) {
            if let aviso = viewModel.avisoDaChamada {
                HStack(spacing: 8) {
                    Text(aviso.texto)
                        .m3(.bodyMedium)
                        .foregroundColor(M3.surface)
                        .padding(.leading, 16)
                    if let arquivo = aviso.arquivo {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([arquivo])
                            viewModel.avisoDaChamada = nil
                        } label: {
                            Text("Mostrar no Finder")
                                .font(M3Tipo.fonte(tamanho: 14, peso: 500))
                                .foregroundColor(M3.primaryContainer)
                                .padding(.horizontal, 12)
                                .frame(height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    M3BotaoDeIcone(icone: "close", tamanho: 32, ajuda: "Fechar") { viewModel.avisoDaChamada = nil }
                        .foregroundColor(M3.surface)
                }
                .padding(.vertical, 4)
                .padding(.trailing, 4)
                .background(RoundedRectangle(cornerRadius: M3.Canto.pequeno, style: .continuous).fill(M3.onSurface))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: aviso) {
                    try? await Task.sleep(nanoseconds: UInt64(duracao * 1_000_000_000))
                    if !Task.isCancelled { viewModel.avisoDaChamada = nil }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(M3.Mola.padrao, value: viewModel.avisoDaChamada)
        .allowsHitTesting(viewModel.avisoDaChamada != nil)
    }
}
