import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Cor que muda de valor exato conforme o modo claro/escuro do sistema (fiel ao mockup, que especifica hex por modo).
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Tokens de cor do app do professor, extraídos do design "AulaCast Telas".
public enum AC {
    public static let windowBG = Color.dynamic(light: 0xf2f2f7, dark: 0x1e1e20)
    public static let panelBG = Color.dynamic(light: 0xffffff, dark: 0x232327)
    public static let cardBG = Color.dynamic(light: 0xffffff, dark: 0x26262a)
    public static let inputBG = Color.dynamic(light: 0xf7f7f9, dark: 0x1c1c20)

    public static let border = Color.dynamic(light: 0xdedee3, dark: 0x34343a)
    public static let borderSubtle = Color.dynamic(light: 0xececf0, dark: 0x2e2e34)

    public static let textPrimary = Color.dynamic(light: 0x1c1c1e, dark: 0xf2f2f5)
    public static let textSecondary = Color.dynamic(light: 0x6b6b72, dark: 0x9a9aa2)
    public static let textTertiary = Color.dynamic(light: 0x8a8a90, dark: 0x6d6d75)

    public static let accent = Color.dynamic(light: 0x007aff, dark: 0x0a84ff)
    public static let stopRed = Color(hex: 0xff453a)
    public static let liveGreen = Color(hex: 0x32d74b)
    public static let pausedAmber = Color(hex: 0xff9f0a)
    public static let offlineRed = Color.dynamic(light: 0xb32b21, dark: 0xff6961)

    public static let chatBubbleOther = Color.dynamic(light: 0xececf0, dark: 0x3a3a41)
}

/// Botão customizado que reproduz exatamente altura/raio/tipografia do mockup,
/// em vez de herdar o chrome padrão do macOS (que ignora boa parte do styling).
public struct ACButtonStyle: ButtonStyle {
    public enum Kind {
        case filled(Color)
        case outline
    }

    let kind: Kind
    let height: CGFloat
    /// Largura fixa para botões de ícone quadrados. Sem isso o fundo encolhe até o tamanho
    /// do ícone e o botão vira uma pílula estreita em vez de um quadrado.
    let width: CGFloat?
    let expands: Bool
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let horizontalPadding: CGFloat

    public init(
        _ kind: Kind,
        height: CGFloat = 34,
        width: CGFloat? = nil,
        expands: Bool = false,
        cornerRadius: CGFloat = 8,
        fontSize: CGFloat = 14,
        fontWeight: Font.Weight = .semibold,
        horizontalPadding: CGFloat = 16
    ) {
        self.kind = kind
        self.height = height
        self.width = width
        self.expands = expands
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.horizontalPadding = horizontalPadding
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundColor(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(width: width)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(background)
            )
            .overlay(
                // Véu escuro no toque: funciona igual em botão claro ou colorido,
                // ao contrário de mexer só na opacidade (invisível sobre fundo claro).
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.black.opacity(pressed ? 0.16 : 0))
            )
            .overlay(
                Group {
                    if case .outline = kind {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(AC.border, lineWidth: 1)
                    }
                }
            )
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var background: Color {
        switch kind {
        case .filled(let color): return color
        case .outline: return AC.cardBG
        }
    }

    private var foreground: Color {
        switch kind {
        case .filled: return .white
        case .outline: return AC.textPrimary
        }
    }
}

extension ButtonStyle where Self == ACButtonStyle {
    public static func acFilled(
        _ color: Color = AC.accent,
        height: CGFloat = 34,
        expands: Bool = false,
        cornerRadius: CGFloat = 8,
        fontSize: CGFloat = 14,
        horizontalPadding: CGFloat = 16
    ) -> ACButtonStyle {
        ACButtonStyle(
            .filled(color),
            height: height,
            expands: expands,
            cornerRadius: cornerRadius,
            fontSize: fontSize,
            horizontalPadding: horizontalPadding
        )
    }

    public static func acOutline(
        height: CGFloat = 34,
        expands: Bool = false,
        cornerRadius: CGFloat = 8,
        fontSize: CGFloat = 14,
        horizontalPadding: CGFloat = 16
    ) -> ACButtonStyle {
        ACButtonStyle(
            .outline,
            height: height,
            expands: expands,
            cornerRadius: cornerRadius,
            fontSize: fontSize,
            fontWeight: .medium,
            horizontalPadding: horizontalPadding
        )
    }

    /// Botão de ícone quadrado (pausa, engrenagem, copiar).
    public static func acIcon(
        size: CGFloat = 34,
        cornerRadius: CGFloat = 8,
        fontSize: CGFloat = 14,
        filled: Color? = nil
    ) -> ACButtonStyle {
        ACButtonStyle(
            filled.map { ACButtonStyle.Kind.filled($0) } ?? .outline,
            height: size,
            width: size,
            cornerRadius: cornerRadius,
            fontSize: fontSize,
            fontWeight: .medium,
            horizontalPadding: 0
        )
    }
}

/// Seletor em cápsula (substitui o Picker segmentado nativo, que o macOS redesenha com o próprio chrome).
public struct ACSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    public init(options: [(value: Value, label: String)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Text(option.label)
                    .font(.system(size: 14, weight: selection == option.value ? .semibold : .regular))
                    .foregroundColor(selection == option.value ? .white : AC.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selection == option.value ? AC.accent : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selection = option.value
                        }
                    }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(AC.inputBG))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AC.border, lineWidth: 1))
    }
}

/// Ponto pulsante usado nos indicadores "AO VIVO" (fiel à animação `pulseDot` do mockup).
public struct ACPulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var pulse = false

    public init(color: Color, size: CGFloat = 9) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? 1 : 0.45)
            .scaleEffect(pulse ? 1 : 0.85)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
