import SwiftUI

/// O símbolo do AulaCast: um ponto com duas ondas de transmissão.
///
/// É o mesmo traçado do favicon da página do aluno e do ícone do aplicativo, redesenhado
/// aqui como `Shape` para que a marca seja a mesma em toda parte, em qualquer tamanho.
public struct ACBroadcastSymbol: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        // Desenhado num sistema de 24x24 (o mesmo do SVG) e ajustado ao retângulo recebido.
        var desenho = Path()

        desenho.addEllipse(in: CGRect(x: 10, y: 10, width: 4, height: 4))

        desenho.move(to: CGPoint(x: 16.2, y: 7.8))
        desenho.addCurve(
            to: CGPoint(x: 16.2, y: 16.3),
            control1: CGPoint(x: 18.5, y: 10.1),
            control2: CGPoint(x: 18.5, y: 13.9)
        )

        desenho.move(to: CGPoint(x: 19.1, y: 4.9))
        desenho.addCurve(
            to: CGPoint(x: 19.1, y: 19.1),
            control1: CGPoint(x: 23.0, y: 8.8),
            control2: CGPoint(x: 23.0, y: 15.2)
        )

        // As ondas só existem à direita, então o desenho não é simétrico: centralizamos
        // pelos limites reais do traçado, e não pela caixa de 24x24.
        let limites = CGRect(x: 9, y: 3.9, width: 14, height: 16.2)
        let escala = min(rect.width / limites.width, rect.height / limites.height)

        let ajuste = CGAffineTransform.identity
            .translatedBy(
                x: rect.midX - (limites.midX * escala),
                y: rect.midY - (limites.midY * escala)
            )
            .scaledBy(x: escala, y: escala)

        return desenho.applying(ajuste)
    }
}

/// Marca do aplicativo: o símbolo em branco sobre o quadrado azul arredondado.
public struct ACBrandMark: View {
    let tamanho: CGFloat

    public init(tamanho: CGFloat = 34) {
        self.tamanho = tamanho
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tamanho * 0.2237, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0A8CFF), Color(hex: 0x005CDB)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            ACBroadcastSymbol()
                .stroke(Color.white, style: StrokeStyle(lineWidth: tamanho * 0.083, lineCap: .round))
                .padding(tamanho * 0.24)
        }
        .frame(width: tamanho, height: tamanho)
    }
}
