import SwiftUI

/// Pop-up com o tempo de um aluno na aula (RF-20), centrado sobre a janela.
/// Só existe na árvore enquanto aberto: o relógio de 1 s para junto com ele.
struct StudentDetailOverlay: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        ZStack {
            if let id = viewModel.alunoAberto {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { fechar() }
                    .accessibilityHidden(true)
                    .transition(.opacity.animation(M3.Mola.efeito))

                StudentDetailCard(viewModel: viewModel, clientId: id, fechar: fechar)
                    .transition(.scale(scale: 0.92).combined(with: .opacity).animation(M3.Mola.lenta))
            }
        }
        .animation(M3.Mola.efeito, value: viewModel.alunoAberto)
    }

    private func fechar() { viewModel.alunoAberto = nil }
}

private struct StudentDetailCard: View {
    @ObservedObject var viewModel: MainViewModel
    let clientId: String
    let fechar: () -> Void

    private static let hora: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        // Um quadro por segundo basta: os números só mudam em segundos.
        TimelineView(.periodic(from: .now, by: 1)) { contexto in
            if let resumo = viewModel.ledger.resumo(clientId: clientId, agora: contexto.date) {
                conteudo(resumo)
            }
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: M3.Canto.extraGrande, style: .continuous)
                .fill(M3.surfaceContainerHigh)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .background(
            Button("Fechar", action: fechar)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private func conteudo(_ r: AttendanceSummary) -> some View {
        let nome = r.nome ?? viewModel.clientManager.clients.first { $0.id == clientId }?.name ?? "Aluno"
        let porcentagem = Int((r.fracaoAVista * 100).rounded())
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                AvatarDeIniciais(nome: nome)
                VStack(alignment: .leading, spacing: 0) {
                    Text(nome).m3(.titleMedium).foregroundColor(M3.onSurface).lineLimit(1)
                    Text("\(r.ip) · entrou às \(Self.hora.string(from: r.entrouAs))")
                        .m3(.bodyMedium).foregroundColor(M3.onSurfaceVariant).lineLimit(1)
                }
                Spacer(minLength: 0)
                M3BotaoDeIcone(icone: "close", tamanho: 40, ajuda: "Fechar") { fechar() }
            }

            HStack(alignment: .top, spacing: 16) {
                destaque("Na aula", formatarDuracao(r.naAula))
                destaque("Com a aula à vista", formatarDuracao(r.aVista))
            }

            VStack(alignment: .leading, spacing: 6) {
                WavyProgress(fracao: r.fracaoAVista)
                    .frame(height: 12)
                Text("\(porcentagem)% do tempo com a aula à vista")
                    .m3(.labelLarge).foregroundColor(M3.onSurfaceVariant)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Com a aula à vista em \(porcentagem)% do tempo")

            VStack(spacing: 0) {
                linha("Saídas da aula (aba ou janela)", "\(r.saidas)")
                linha("Maior trecho sem sair", formatarDuracao(r.maiorTrecho))
                linha("Desconexões e voltas", "\(r.desconexoes)")
            }
        }
        .padding(24)
    }

    private func destaque(_ titulo: String, _ valor: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo).m3(.labelLarge).foregroundColor(M3.onSurfaceVariant)
            Text(valor)
                .font(M3Tipo.fonte(tamanho: 24, peso: 500).monospacedDigit())
                .foregroundColor(M3.onSurface)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func linha(_ titulo: String, _ valor: String) -> some View {
        HStack {
            Text(titulo).m3(.bodyMedium).foregroundColor(M3.onSurfaceVariant)
            Spacer(minLength: 8)
            Text(valor).m3(.titleSmall).foregroundColor(M3.onSurface).monospacedDigit()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Barra de progresso linear ondulada do Material 3 Expressive: a parte feita é uma onda que
/// anda devagar; o resto é uma linha reta. Parada com "Reduzir movimento".
struct WavyProgress: View {
    let fracao: Double
    @Environment(\.accessibilityReduceMotion) private var reduzirMovimento

    var body: some View {
        if reduzirMovimento {
            barra(fase: 0)
        } else {
            TimelineView(.animation) { contexto in
                barra(fase: contexto.date.timeIntervalSinceReferenceDate * 2)
            }
        }
    }

    private func barra(fase: Double) -> some View {
        ZStack {
            WaveTrack(inicio: fracao, fase: fase, onda: false)
                .stroke(M3.outlineVariant, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            WaveTrack(inicio: 0, fim: fracao, fase: fase, onda: true)
                .stroke(M3.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct WaveTrack: Shape {
    var inicio: Double
    var fim: Double = 1
    var fase: Double
    let onda: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x0 = rect.width * min(max(inicio, 0), 1)
        let x1 = rect.width * min(max(fim, 0), 1)
        guard x1 > x0 else { return p }
        let meio = rect.midY
        guard onda else {
            // Pequeno vão depois da onda, como no indicador do M3.
            p.move(to: CGPoint(x: min(x0 + 8, rect.width), y: meio))
            p.addLine(to: CGPoint(x: rect.width, y: meio))
            return p
        }
        let amplitude: CGFloat = 3, comprimento: CGFloat = 22
        func y(_ x: CGFloat, _ ganho: CGFloat) -> CGFloat {
            meio + amplitude * ganho * sin(CGFloat(fase) - x / comprimento * 2 * .pi)
        }
        var x = x0
        p.move(to: CGPoint(x: x, y: y(x, 0)))
        while x < x1 {
            x = min(x + 2, x1)
            // A amplitude cresce nos primeiros pixels para a onda nascer da ponta.
            p.addLine(to: CGPoint(x: x, y: y(x, min(1, (x - x0) / 12))))
        }
        return p
    }
}
