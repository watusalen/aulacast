import SwiftUI
import CoreGraphics
import AppKit

/// Painel "Apresentar": o professor escolhe o monitor ou a janela que a turma vê.
/// Como o "Apresentar agora" do Meet, fica num painel próprio, e o palco fica só para a
/// imagem que está indo para a turma.
public struct SourcePickerView<CaptureService: ScreenCaptureProtocol>: View {
    @ObservedObject var recorder: CaptureService
    @State private var thumbnails: [String: NSImage] = [:]

    /// Colunas pela largura disponível (uma a cada ~200 pt, de 2 a 6).
    @State private var quantasColunas = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: quantasColunas)
    }

    public static func colunas(paraLargura largura: CGFloat) -> Int {
        max(2, min(6, Int((largura + 14) / 200)))
    }

    public init(recorder: CaptureService) {
        self.recorder = recorder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("O que a turma vai ver")
                    .m3(.bodyMedium)
                    .foregroundColor(M3.onSurfaceVariant)
                Spacer()
                M3BotaoDeIcone(icone: "refresh", variante: .padrao, tamanho: 36, ajuda: "Atualizar a lista") {
                    Task {
                        await recorder.fetchAvailableSources()
                        await captureThumbnails()
                    }
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 12)

            if recorder.availableSources.isEmpty {
                VStack(spacing: 10) {
                    M3Icone(nome: "desktop_windows", tamanho: 40)
                        .foregroundColor(M3.onSurfaceVariant)
                    Text("Nenhuma tela encontrada")
                        .m3(.titleMedium)
                        .foregroundColor(M3.onSurface)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(recorder.availableSources) { source in
                            SourceCard(
                                source: source,
                                thumbnail: thumbnails[source.id],
                                isSelected: recorder.selectedSource?.id == source.id
                            ) {
                                recorder.selectedSource = source
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .animation(M3.Mola.padrao, value: recorder.selectedSource?.id)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { quantasColunas = Self.colunas(paraLargura: geo.size.width - 32) }
                            .onChange(of: geo.size.width) { largura in
                                quantasColunas = Self.colunas(paraLargura: largura - 32)
                            }
                    }
                )
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
        guard source.type == .window else { return "Tela inteira" }
        return source.name.components(separatedBy: "] ").first?.replacingOccurrences(of: "[", with: "") ?? source.name
    }

    static func subtitle(_ source: DisplaySource) -> String {
        guard source.type == .window else { return source.name }
        return source.name.components(separatedBy: "] ").dropFirst().joined()
    }
}

/// Cartão de fonte em Material 3: miniatura com cantos grandes, título e legenda; o
/// selecionado ganha contorno na cor primária e o selo de "check", como na escolha do
/// que apresentar no Meet.
struct SourceCard: View {
    let source: DisplaySource
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // A miniatura entra como overlay de um retângulo com proporção fixa: assim é o
                // retângulo que define o tamanho do card, e não a imagem.
                RoundedRectangle(cornerRadius: M3.Canto.grande, style: .continuous)
                    .fill(M3.surfaceContainerHighest)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay(
                        Group {
                            if let thumbnail = thumbnail {
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                M3Icone(nome: source.type == .display ? "desktop_windows" : "web_asset", tamanho: 28)
                                    .foregroundColor(M3.onSurfaceVariant)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: M3.Canto.grande, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: M3.Canto.grande, style: .continuous)
                            .stroke(isSelected ? M3.primary : M3.outlineVariant, lineWidth: isSelected ? 3 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            M3Icone(nome: "check_circle", tamanho: 24, preenchido: true)
                                .foregroundColor(M3.primary)
                                .background(Circle().fill(M3.surface).padding(3))
                                .padding(8)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                VStack(alignment: .leading, spacing: 0) {
                    Text(SourceNaming.title(source))
                        .m3(.labelLarge)
                        .foregroundColor(isSelected ? M3.primary : M3.onSurface)
                        .lineLimit(1)
                    Text(SourceNaming.subtitle(source))
                        .m3(.bodySmall)
                        .foregroundColor(M3.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardDeFonteEstilo())
        .help(source.name)
    }
}

/// Retorno do clique nos cartões: encolhe levemente, com a mola rápida do M3.
private struct CardDeFonteEstilo: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(M3.Mola.rapida, value: configuration.isPressed)
    }
}
