import SwiftUI

/// Qualidade da transmissão: resolução e quadros por segundo (SRP).
///
/// Cada ajuste vale no instante em que é feito, inclusive com a aula no ar, então não há
/// o que confirmar — por isso não existe botão de "Concluído". É um popover ancorado no
/// botão: fecha clicando fora ou com Esc. (O chat saiu daqui e foi para o painel de chat,
/// onde o Meet põe esse controle.)
public struct QualitySettingsView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var captureService: ScreenCaptureService

    public init(viewModel: MainViewModel, captureService: ScreenCaptureService) {
        self.viewModel = viewModel
        self.captureService = captureService
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Qualidade da transmissão")
                .m3(.titleLarge)
                .foregroundColor(M3.onSurface)

            VStack(alignment: .leading, spacing: 10) {
                Text("Resolução").m3(.labelLarge).foregroundColor(M3.onSurfaceVariant)
                M3GrupoConectado(
                    opcoes: VideoResolution.allCases.map { ($0, $0.rawValue) },
                    selecao: $captureService.resolution
                )
                Text("720p é recomendado para PCs antigos do laboratório.")
                    .m3(.bodySmall)
                    .foregroundColor(M3.onSurfaceVariant)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Quadros por segundo").m3(.labelLarge).foregroundColor(M3.onSurfaceVariant)
                M3GrupoConectado(
                    // 60 fps saiu da lista: foi testado em sala e piorou. Cada quadro
                    // MJPEG é um JPEG inteiro, então dobrar a taxa dobra o tráfego sem
                    // entregar imagem melhor — e o que trava não é o Mac, é a rede.
                    opcoes: [(15, "15"), (30, "30"), (45, "45")],
                    selecao: $captureService.frameRate
                )
                Text("Mais quadros deixam o movimento mais macio, mas multiplicam o tráfego na "
                     + "rede: se a turma começar a travar, é o primeiro a baixar.")
                    .m3(.bodySmall)
                    .foregroundColor(M3.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 340)
        .background(M3.surfaceContainerHigh)
    }
}

/// Grupo de botões conectados do M3 Expressive (substituto do segmented button): botões
/// lado a lado com 2 pt de espaço, cantos internos pequenos e externos redondos; o
/// escolhido fica preenchido, com um "check".
struct M3GrupoConectado<Valor: Hashable>: View {
    let opcoes: [(Valor, String)]
    @Binding var selecao: Valor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(opcoes.enumerated()), id: \.offset) { indice, opcao in
                let escolhido = opcao.0 == selecao
                Button { selecao = opcao.0 } label: {
                    HStack(spacing: 6) {
                        if escolhido {
                            M3Icone(nome: "check", tamanho: 18)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(opcao.1).m3(.labelLarge)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .foregroundColor(escolhido ? M3.onSecondaryContainer : M3.onSurface)
                    .background(
                        forma(indice: indice, escolhido: escolhido)
                            .fill(escolhido ? M3.secondaryContainer : M3.surfaceContainerHighest)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(M3.Mola.padrao, value: selecao)
    }

    /// Cantos externos redondos, internos de 8 pt; o escolhido vira pílula inteira.
    private func forma(indice: Int, escolhido: Bool) -> some Shape {
        let externo: CGFloat = 20
        let interno: CGFloat = escolhido ? 20 : M3.Canto.pequeno
        let primeiro = indice == 0
        let ultimo = indice == opcoes.count - 1
        return CantosDiferentes(
            superiorEsquerdo: primeiro ? externo : interno,
            inferiorEsquerdo: primeiro ? externo : interno,
            superiorDireito: ultimo ? externo : interno,
            inferiorDireito: ultimo ? externo : interno
        )
    }
}

/// Retângulo com um raio por canto (o `UnevenRoundedRectangle` só existe no macOS 14).
struct CantosDiferentes: Shape {
    var superiorEsquerdo: CGFloat
    var inferiorEsquerdo: CGFloat
    var superiorDireito: CGFloat
    var inferiorDireito: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(superiorEsquerdo, inferiorEsquerdo), .init(superiorDireito, inferiorDireito)) }
        set {
            superiorEsquerdo = newValue.first.first
            inferiorEsquerdo = newValue.first.second
            superiorDireito = newValue.second.first
            inferiorDireito = newValue.second.second
        }
    }

    func path(in r: CGRect) -> Path {
        func limite(_ v: CGFloat) -> CGFloat { min(v, min(r.width, r.height) / 2) }
        let se = limite(superiorEsquerdo), ie = limite(inferiorEsquerdo)
        let sd = limite(superiorDireito), id = limite(inferiorDireito)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + se, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - sd, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - sd, y: r.minY + sd), radius: sd, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - id))
        p.addArc(center: CGPoint(x: r.maxX - id, y: r.maxY - id), radius: id, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + ie, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + ie, y: r.maxY - ie), radius: ie, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + se))
        p.addArc(center: CGPoint(x: r.minX + se, y: r.minY + se), radius: se, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
