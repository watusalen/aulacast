import SwiftUI
import CoreGraphics
import AppKit

/// Componente para selecao de monitor ou janela para transmitir, com preview real (DIP).
/// Grade responsiva de 3 colunas iguais (como no mockup) — os cards ocupam a largura
/// disponível em vez de um tamanho fixo em pixels, e a seção inteira rola verticalmente
/// junto com o resto do painel (sem rolagem horizontal escondida).
public struct SourcePickerView<CaptureService: ScreenCaptureProtocol>: View {
    @ObservedObject var recorder: CaptureService
    @State private var thumbnails: [String: NSImage] = [:]

    /// Colunas pela largura disponível (uma a cada ~200 pt, de 2 a 6). Com 3 colunas fixas
    /// os cards ficavam enormes numa janela larga e a grade mal mostrava uma linha inteira.
    @State private var quantasColunas = 3

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: quantasColunas)
    }

    public static func colunas(paraLargura largura: CGFloat) -> Int {
        max(2, min(6, Int((largura + 14) / 200)))
    }

    public init(recorder: CaptureService) {
        self.recorder = recorder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Fonte de captura")
                    .font(.system(size: 13))
                    .foregroundColor(AC.textSecondary)
                Spacer()
                Button(action: {
                    Task {
                        await recorder.fetchAvailableSources()
                        await captureThumbnails()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.acIcon(size: 28, cornerRadius: 7, fontSize: 12))
                .help("Atualizar fontes")
            }

            if recorder.availableSources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 26))
                        .foregroundColor(AC.textTertiary)
                    Text("Nenhuma fonte encontrada.")
                        .font(.system(size: 13))
                        .foregroundColor(AC.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                // A rolagem fica contida nesta área: o restante do painel esquerdo
                // (cabeçalho, prévia, botões e endereço) permanece sempre visível.
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(recorder.availableSources) { source in
                            SourceCard(
                                source: source,
                                thumbnail: thumbnails[source.id],
                                isSelected: recorder.selectedSource?.id == source.id
                            ) {
                                recorder.selectedSource = source
                            }
                        }
                        // Um único card-convite ao final, como no mockup. Preencher a linha
                        // inteira duplicava a mesma mensagem lado a lado.
                        if showsPlaceholderCard {
                            SourcePlaceholderCard()
                        }
                    }
                    .padding(.bottom, 4)
                    // Espaço para a barra de rolagem: no macOS ela flutua por cima do
                    // conteúdo e cobria a borda direita dos cards da última coluna.
                    .padding(.trailing, 14)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { quantasColunas = Self.colunas(paraLargura: geo.size.width - 14) }
                            .onChange(of: geo.size.width) { largura in
                                quantasColunas = Self.colunas(paraLargura: largura - 14)
                            }
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            await manterListaAtualizada()
        }
    }

    /// Revarre as fontes de tempos em tempos.
    ///
    /// Sem isto a lista só mudava ao clicar em "Atualizar": um app fechado no meio da aula
    /// continuava oferecido como fonte, e um app recém-aberto não aparecia. Refazer a busca
    /// também limpa a seleção quando a janela escolhida deixa de existir.
    private func manterListaAtualizada() async {
        while !Task.isCancelled {
            await recorder.fetchAvailableSources()
            await captureThumbnails()

            // A varredura captura uma miniatura por fonte, então não vale repetir depressa —
            // e durante a transmissão ela espaça ainda mais, para não disputar CPU com o
            // envio dos quadros, que é o que a turma está vendo.
            let intervalo: UInt64 = recorder.isRecording ? 15_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: intervalo)
        }
    }

    /// O card-convite só faz sentido quando ainda há espaço sobrando na última linha:
    /// se a linha já está cheia, ele abriria uma linha nova só para si.
    private var showsPlaceholderCard: Bool {
        recorder.availableSources.count % quantasColunas != 0
    }

    private func captureThumbnails() async {
        // Fora da thread principal. Como método de uma View, isto herda a MainActor, e
        // capturar e reduzir uma imagem por janela ali congelava a interface a cada volta.
        let fontes = recorder.availableSources
        let geradas = await Task.detached(priority: .utility) { () -> Miniaturas in
            let provider = SourceThumbnailProvider()
            var imagens: [String: NSImage] = [:]
            for source in fontes {
                if let image = provider.thumbnail(for: source) {
                    imagens[source.id] = image
                }
            }
            return Miniaturas(imagens: imagens)
        }.value
        thumbnails = geradas.imagens
    }
}

/// As imagens nascem na tarefa de fundo e só são lidas na principal depois dela
/// terminar; o NSImage só se declara Sendable a partir do macOS 14.
private struct Miniaturas: @unchecked Sendable {
    let imagens: [String: NSImage]
}

/// Extrai nome do app / subtítulo do rótulo combinado de DisplaySource ("[App] Título").
enum SourceNaming {
    static func title(_ source: DisplaySource) -> String {
        guard source.type == .window else { return "Monitor Completo" }
        return source.name.components(separatedBy: "] ").first?.replacingOccurrences(of: "[", with: "") ?? source.name
    }

    static func subtitle(_ source: DisplaySource) -> String {
        guard source.type == .window else { return source.name }
        return source.name.components(separatedBy: "] ").dropFirst().joined()
    }
}

struct SourceCard: View {
    let source: DisplaySource
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // A miniatura entra como overlay de um retângulo com proporção fixa: assim é o
                // retângulo que define o tamanho do card, e não a imagem (que, em .fill, reporta
                // um tamanho ideal enorme e fazia o card estourar a largura da coluna).
                Rectangle()
                    .fill(AC.windowBG)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay(
                        Group {
                            if let thumbnail = thumbnail {
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: source.type == .display ? "desktopcomputer" : "macwindow")
                                    .font(.system(size: 22))
                                    .foregroundColor(AC.textTertiary)
                            }
                        }
                    )
                    .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    Text(SourceNaming.title(source))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? AC.accent : AC.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(SourceNaming.subtitle(source))
                        .font(.system(size: 11))
                        .foregroundColor(AC.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxWidth: .infinity)
            .background(isSelected ? AC.accent.opacity(0.08) : AC.cardBG)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? AC.accent : AC.border, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(SourceCardButtonStyle())
    }
}

/// Feedback de toque dos cards de fonte (o estilo .plain não dá nenhum retorno visual).
private struct SourceCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Card tracejado que fecha a grade, convidando a abrir mais um app.
/// Espelha a estrutura do SourceCard (miniatura + bloco de legenda) para ter exatamente
/// a mesma altura dos cards reais em qualquer largura de janela.
struct SourcePlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.clear)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)

            // Espaçador com as mesmas fontes da legenda dos cards reais: garante altura
            // idêntica sem depender de números fixos que quebrariam ao mudar a tipografia.
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: " ").font(.system(size: 13, weight: .semibold))
                Text(verbatim: " ").font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .hidden()
        }
        .frame(maxWidth: .infinity)
        // O texto fica sobre o card inteiro (miniatura + legenda), e não só sobre a
        // área da miniatura, para ficar centralizado no meio real do card.
        .overlay(
            Text("Abra um app para vê-lo aqui")
                .font(.system(size: 12))
                .foregroundColor(AC.textTertiary)
                .multilineTextAlignment(.center)
                .padding(10)
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AC.windowBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AC.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}
