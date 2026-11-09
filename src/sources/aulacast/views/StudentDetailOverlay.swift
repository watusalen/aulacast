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

                StudentDetailCard(viewModel: viewModel, pessoaId: id, fechar: fechar)
                    .transition(.scale(scale: 0.92).combined(with: .opacity).animation(M3.Mola.lenta))
            }
        }
        .animation(M3.Mola.efeito, value: viewModel.alunoAberto)
    }

    private func fechar() { viewModel.alunoAberto = nil }
}

private struct StudentDetailCard: View {
    @ObservedObject var viewModel: MainViewModel
    let pessoaId: String
    let fechar: () -> Void

    @State private var nomesAbertos = false

    private static let hora: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        // Um quadro por segundo basta: os números só mudam em segundos.
        TimelineView(.periodic(from: .now, by: 1)) { contexto in
            if let resumo = viewModel.ledger.resumo(pessoaId: pessoaId, agora: contexto.date) {
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
        let nome = r.nome ?? "Participante"
        let porcentagem = Int((r.fracaoAVista * 100).rounded())
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                AvatarDeIniciais(nome: nome)
                VStack(alignment: .leading, spacing: 0) {
                    Text(nome).m3(.titleMedium).foregroundColor(M3.onSurface).lineLimit(1)
                    Text("IP \(r.ip) · entrou às \(Self.hora.string(from: r.entrouAs))")
                        .m3(.bodyMedium).foregroundColor(M3.onSurfaceVariant).lineLimit(1)
                }
                Spacer(minLength: 0)
                M3BotaoDeIcone(icone: "close", tamanho: 40, ajuda: "Fechar") { fechar() }
            }

            HStack(alignment: .top, spacing: 16) {
                destaque("Na transmissão", formatarDuracao(r.naAula))
                destaque("Vendo a transmissão", formatarDuracao(r.aVista))
            }

            VStack(alignment: .leading, spacing: 6) {
                WavyProgress(fracao: r.fracaoAVista)
                    .frame(height: 12)
                Text("\(porcentagem)% do tempo vendo a transmissão")
                    .m3(.labelLarge).foregroundColor(M3.onSurfaceVariant)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Vendo a transmissão em \(porcentagem)% do tempo")

            VStack(spacing: 0) {
                linha("Saídas (aba ou janela)", "\(r.saidas)")
                linha("Maior tempo seguido", formatarDuracao(r.maiorTrecho))
                linha("Desconexões e voltas", "\(r.desconexoes)")
                // Conectadas primeiro (pela hora de entrada), depois as que já saíram, da mais recente
                // para a mais antiga. `sorted` é estável: no máximo 20 itens por pessoa.
                if r.conexoes.count > 1 { nomesUsados(Self.ativasPrimeiro(r.conexoes)) }
            }
        }
        .padding(24)
    }

    /// Última linha: "Nomes usados (N)" expande uma linha do tempo, do primeiro nome ao atual.
    private func nomesUsados(_ nomes: [ConexaoDaPessoa]) -> some View {
        VStack(spacing: 0) {
            M3Divisor()
            Button { withAnimation(M3.Mola.padrao) { nomesAbertos.toggle() } } label: {
                HStack {
                    Text("Nomes usados (\(nomes.count))").m3(.bodyMedium).foregroundColor(M3.onSurfaceVariant)
                    Spacer(minLength: 8)
                    // `expand_more` não está na fonte reduzida de ícones (nunca apareceu):
                    // o `chevron_right` está, e gira para baixo (fechado) e para cima (aberto).
                    M3Icone(nome: "chevron_right", tamanho: 22)
                        .foregroundColor(M3.onSurfaceVariant)
                        .rotationEffect(.degrees(nomesAbertos ? -90 : 90))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(nomesAbertos ? "Expandido" : "Recolhido")

            if nomesAbertos {
                // A altura é a dos nomes, nem um ponto a mais: um `ScrollView` ocupa sempre o
                // máximo que lhe derem e deixava sobra de espaço com poucos nomes. Só rola
                // quando passa de `limiteSemRolagem` nomes.
                Group {
                    if nomes.count > Self.limiteSemRolagem {
                        ScrollView { listaDeNomes(nomes) }
                            .frame(height: Self.alturaComRolagem)
                    } else {
                        listaDeNomes(nomes)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .animation(M3.Mola.padrao, value: nomesAbertos)
    }

    /// Conectadas primeiro, pela hora de entrada; depois as que saíram, a mais recente em cima.
    static func ativasPrimeiro(_ lista: [ConexaoDaPessoa]) -> [ConexaoDaPessoa] {
        let ativas = lista.filter { $0.ativa }.sorted { $0.entrouAs < $1.entrouAs }
        let saidas = lista.filter { !$0.ativa }.sorted { $0.entrouAs > $1.entrouAs }
        return ativas + saidas
    }

    /// Até quantos nomes cabem sem rolar, e a altura da área quando passa disso.
    private static let limiteSemRolagem = 4
    private static let alturaComRolagem: CGFloat = 4 * 48

    private func listaDeNomes(_ nomes: [ConexaoDaPessoa]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(nomes.enumerated()), id: \.offset) { i, n in
                itemDaLinhaDoTempo(n, ultimo: i == nomes.count - 1)
            }
        }
        .padding(.top, 4)
    }

    /// Altura própria do item; o conector é um fundo que desce até o próximo ponto (item + 12 pt
    /// de vão), então não há espaço sobrando nem depois do último.
    private func itemDaLinhaDoTempo(_ n: ConexaoDaPessoa, ultimo: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PontoDeConexao(ativa: n.ativa).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.nome).m3(.titleSmall).foregroundColor(M3.onSurface).lineLimit(1)
                // Hora de entrada e, se o ENV já chegou, o navegador e o aparelho (um palpite).
                Text(["entrou às \(Self.hora.string(from: n.entrouAs))", n.descricao].compactMap { $0 }.joined(separator: " · "))
                    .m3(.bodySmall).foregroundColor(M3.onSurfaceVariant).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .topLeading) {
            if !ultimo {
                Rectangle().fill(M3.outlineVariant).frame(width: 2)
                    .padding(.top, 13).padding(.leading, 3).padding(.bottom, -12)
            }
        }
        .accessibilityElement(children: .combine)
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
/// Bolinha da conexão: azul que "respira" enquanto conectada, vazia depois que saiu. As duas têm
/// o MESMO tamanho (8 pt): o pulso é só a opacidade indo de cheia a fraca e voltando, sem anel que
/// cresça (um anel faria a azul parecer maior e seria cortado pela lista). Com "Reduzir movimento"
/// ligado, fica o azul parado.
///
/// A animação é do Core Animation, não do SwiftUI: uma `repeatForever` do SwiftUI redesenhava a
/// lista a cada quadro e a rolagem engasgava. Medido num teste à parte: as duas bolinhas ocupam
/// 16x16 px (8 pt) e a opacidade da azul varia entre 0,3 e 1 em ciclos de 2,4 s.
private struct PontoDeConexao: View {
    let ativa: Bool

    var body: some View {
        Group {
            if ativa {
                PontoAzul(cor: NSColor(M3.primary), pulsa: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            } else {
                ZStack {
                    Circle().fill(M3.surface)
                    Circle().strokeBorder(M3.outline, lineWidth: 1.5)
                }
            }
        }
        .frame(width: 8, height: 8)
    }
}

private struct PontoAzul: NSViewRepresentable {
    let cor: NSColor
    let pulsa: Bool

    func makeNSView(context: Context) -> VistaDoPonto { VistaDoPonto(cor: cor, pulsa: pulsa) }
    func updateNSView(_ vista: VistaDoPonto, context: Context) { vista.cor = cor }
}

private final class VistaDoPonto: NSView {
    var cor: NSColor { didSet { pintar() } }
    private let pulsa: Bool
    private let ponto = CALayer()

    init(cor: NSColor, pulsa: Bool) {
        self.cor = cor
        self.pulsa = pulsa
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        wantsLayer = true
        ponto.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        ponto.cornerRadius = 4
        layer?.addSublayer(ponto)
        pintar()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// O Core Animation descarta animações de uma camada que sai da janela (a lista rola, a vista
    /// é reaproveitada): por isso ela é criada de novo toda vez que a vista entra numa janela.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ponto.removeAnimation(forKey: "respirar")
        guard window != nil, pulsa else { return }
        let respirar = CABasicAnimation(keyPath: "opacity")
        respirar.fromValue = 1
        respirar.toValue = 0.3
        respirar.duration = 1.2
        respirar.autoreverses = true
        respirar.repeatCount = .infinity
        respirar.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ponto.add(respirar, forKey: "respirar")
    }

    /// A cor muda com o tema claro/escuro: resolvida de novo quando a aparência muda.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pintar()
    }

    private func pintar() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ponto.backgroundColor = cor.cgColor
        }
    }
}

struct WavyProgress: View {
    let fracao: Double
    @Environment(\.accessibilityReduceMotion) private var reduzirMovimento

    var body: some View {
        if reduzirMovimento {
            barra(fase: 0)
        } else {
            // 30 quadros por segundo bastam para uma onda lenta; a cada quadro da tela (60 a 120)
            // o pop-up inteiro competia com a rolagem da lista.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { contexto in
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
