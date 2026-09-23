import SwiftUI
import AppKit
import CoreText

// Material 3 (Expressive) para o app do professor, em SwiftUI.
//
// Não há biblioteca oficial de Material para o Mac: a Material Components for iOS está
// em manutenção desde 2021 e só roda em iOS/UIKit. Por isso os tokens (cor, tipo, forma,
// movimento) estão aqui, com os valores do Material 3, e o que vem de biblioteca oficial
// são as fontes: Google Sans Flex (OFL) e Material Symbols Rounded (Apache 2.0),
// recortadas só para o que o app usa, em src/assets/fonts.

// MARK: - Fontes

enum M3Fontes {
    static let familiaDeTexto = "Google Sans Flex"
    static let familiaDeIcones = "Material Symbols Rounded"

    /// Registra as fontes do app uma única vez, na primeira vez que alguém pedir uma.
    private static let registro: Bool = {
        guard let pasta = pastaDasFontes() else { return false }
        let arquivos = (try? FileManager.default.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil)) ?? []
        var algum = false
        for arquivo in arquivos where arquivo.pathExtension.lowercased() == "ttf" {
            if CTFontManagerRegisterFontsForURL(arquivo as CFURL, .process, nil) { algum = true }
        }
        return algum
    }()

    /// Mesma busca da pasta do site: dentro do .app, rodando de src/ ou da raiz, ou subindo
    /// a partir do executável do SwiftPM.
    static func pastaDasFontes() -> URL? {
        let fm = FileManager.default
        let atual = URL(fileURLWithPath: fm.currentDirectoryPath)
        var candidatos: [URL] = []
        if let recursos = Bundle.main.resourceURL { candidatos.append(recursos.appendingPathComponent("fonts")) }
        candidatos.append(atual.appendingPathComponent("assets/fonts"))
        candidatos.append(atual.appendingPathComponent("src/assets/fonts"))
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            guard dir.path != "/" else { break }
            candidatos.append(dir.appendingPathComponent("assets/fonts"))
            candidatos.append(dir.appendingPathComponent("src/assets/fonts"))
        }
        return candidatos.first { var p: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &p) && p.boolValue }
    }

    private static var cache: [String: NSFont] = [:]

    /// Fonte variável com os eixos pedidos (peso, tamanho óptico, preenchimento).
    static func fonte(_ familia: String, tamanho: CGFloat, eixos: [String: CGFloat]) -> NSFont? {
        _ = registro
        let chave = "\(familia)|\(tamanho)|\(eixos.sorted { $0.key < $1.key })"
        if let pronta = cache[chave] { return pronta }
        var variacoes: [NSNumber: CGFloat] = [:]
        for (tag, valor) in eixos { variacoes[NSNumber(value: codigoDoEixo(tag))] = valor }
        let descritor = NSFontDescriptor(fontAttributes: [
            .family: familia,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variacoes
        ])
        guard let fonte = NSFont(descriptor: descritor, size: tamanho), fonte.familyName == familia else { return nil }
        cache[chave] = fonte
        return fonte
    }

    private static func codigoDoEixo(_ tag: String) -> UInt32 {
        tag.unicodeScalars.reduce(0) { ($0 << 8) | $1.value }
    }
}

// MARK: - Cores (esquema do Google em Material 3, claro e escuro)

enum M3 {
    static let primary = Color.dynamic(light: 0x0B57D0, dark: 0xA8C7FA)
    static let onPrimary = Color.dynamic(light: 0xFFFFFF, dark: 0x062E6F)
    static let primaryContainer = Color.dynamic(light: 0xD3E3FD, dark: 0x0842A0)
    static let onPrimaryContainer = Color.dynamic(light: 0x041E49, dark: 0xD3E3FD)
    static let secondaryContainer = Color.dynamic(light: 0xC2E7FF, dark: 0x004A77)
    static let onSecondaryContainer = Color.dynamic(light: 0x001D35, dark: 0xC2E7FF)
    static let tertiary = Color.dynamic(light: 0x146C2E, dark: 0x6DD58C)
    static let tertiaryContainer = Color.dynamic(light: 0xC4EED0, dark: 0x0F5223)
    static let onTertiaryContainer = Color.dynamic(light: 0x072711, dark: 0xC4EED0)
    static let error = Color.dynamic(light: 0xB3261E, dark: 0xF2B8B5)
    static let onError = Color.dynamic(light: 0xFFFFFF, dark: 0x601410)
    static let errorContainer = Color.dynamic(light: 0xF9DEDC, dark: 0x8C1D18)
    static let onErrorContainer = Color.dynamic(light: 0x410E0B, dark: 0xF9DEDC)
    /// Vermelho do "encerrar" (como o botão de sair da chamada do Meet), igual nos dois modos.
    static let danger = Color(hex: 0xDC362E)
    static let onDanger = Color.white
    static let warningContainer = Color.dynamic(light: 0xFFDF99, dark: 0x5C4300)
    static let onWarningContainer = Color.dynamic(light: 0x261A00, dark: 0xFFDF99)

    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x131314)
    static let surfaceContainerLowest = Color.dynamic(light: 0xFFFFFF, dark: 0x0E0E0E)
    static let surfaceContainerLow = Color.dynamic(light: 0xF8FAFD, dark: 0x1B1B1B)
    static let surfaceContainer = Color.dynamic(light: 0xF0F4F9, dark: 0x1E1F20)
    static let surfaceContainerHigh = Color.dynamic(light: 0xE9EEF6, dark: 0x282A2C)
    static let surfaceContainerHighest = Color.dynamic(light: 0xDDE3EA, dark: 0x333537)
    static let onSurface = Color.dynamic(light: 0x1F1F1F, dark: 0xE3E3E3)
    static let onSurfaceVariant = Color.dynamic(light: 0x444746, dark: 0xC4C7C5)
    static let outline = Color.dynamic(light: 0x747775, dark: 0x8E918F)
    static let outlineVariant = Color.dynamic(light: 0xC4C7C5, dark: 0x444746)

    // MARK: Formas (cantos do Material 3)
    enum Canto {
        static let extraPequeno: CGFloat = 4
        static let pequeno: CGFloat = 8
        static let medio: CGFloat = 12
        static let grande: CGFloat = 16
        static let extraGrande: CGFloat = 28
    }

    // MARK: Movimento (molas do M3 Expressive: rigidez 1400/700/300, amortecimento 0,9)
    enum Mola {
        static let rapida = Animation.spring(response: 0.17, dampingFraction: 0.9)
        static let padrao = Animation.spring(response: 0.24, dampingFraction: 0.9)
        static let lenta = Animation.spring(response: 0.36, dampingFraction: 0.9)
        /// Para cor e opacidade: sem ultrapassar o alvo.
        static let efeito = Animation.spring(response: 0.24, dampingFraction: 1)
    }
}

// MARK: - Tipografia (escala do Material 3 em Google Sans Flex)

enum M3Tipo {
    case displaySmall, headlineSmall, titleLarge, titleMedium, titleSmall
    case bodyLarge, bodyMedium, bodySmall, labelLarge, labelMedium, labelSmall

    var tamanho: CGFloat {
        switch self {
        case .displaySmall: return 36
        case .headlineSmall: return 24
        case .titleLarge: return 22
        case .titleMedium: return 16
        case .titleSmall: return 14
        case .bodyLarge: return 16
        case .bodyMedium: return 14
        case .bodySmall: return 12
        case .labelLarge: return 14
        case .labelMedium: return 12
        case .labelSmall: return 11
        }
    }

    var peso: CGFloat {
        switch self {
        case .titleMedium, .titleSmall, .labelLarge, .labelMedium, .labelSmall: return 500
        default: return 400
        }
    }

    var fonte: Font {
        M3Tipo.fonte(tamanho: tamanho, peso: peso)
    }

    static func fonte(tamanho: CGFloat, peso: CGFloat) -> Font {
        if let nsFont = M3Fontes.fonte(M3Fontes.familiaDeTexto, tamanho: tamanho,
                                       eixos: ["wght": peso, "opsz": tamanho]) {
            return Font(nsFont)
        }
        let equivalente: Font.Weight = peso >= 600 ? .semibold : peso >= 500 ? .medium : .regular
        return .system(size: tamanho, weight: equivalente)
    }
}

extension View {
    func m3(_ tipo: M3Tipo) -> some View { font(tipo.fonte) }
}

// MARK: - Ícones (Material Symbols Rounded)

struct M3Icone: View {
    let nome: String
    var tamanho: CGFloat = 24
    /// Preenchido marca estado ativo, como os ícones do Meet.
    var preenchido = false
    var peso: CGFloat = 400

    static let codigos: [String: UInt32] = [
        "add": 0xE145,
        "attach_file": 0xE226,
        "cancel": 0xE888,
        "cast": 0xE307,
        "cast_for_education": 0xEFEC,
        "chat": 0xE0C9,
        "check": 0xE668,
        "check_circle": 0xF0BE,
        "chevron_right": 0xE5CC,
        "circle": 0xEF4A,
        "close": 0xE5CD,
        "co_present": 0xEAF0,
        "content_copy": 0xE14D,
        "description": 0xE873,
        "desktop_windows": 0xE30C,
        "download": 0xF090,
        "draft": 0xE66D,
        "error": 0xF8B6,
        "file_present": 0xEA0E,
        "folder": 0xE2C7,
        "forum": 0xE8AF,
        "group": 0xEA21,
        "info": 0xE88E,
        "ios_share": 0xE6B8,
        "keyboard_arrow_down": 0xE313,
        "lan": 0xEB2F,
        "mark_chat_unread": 0xF189,
        "more_vert": 0xE5D4,
        "open_in_new": 0xE89E,
        "pause": 0xE034,
        "pause_circle": 0xE1A2,
        "person": 0xF0D3,
        "play_arrow": 0xE037,
        "play_circle": 0xE1C4,
        "present_to_all": 0xE0DF,
        "radio_button_checked": 0xE837,
        "refresh": 0xE5D5,
        "schedule": 0xEFD6,
        "screen_share": 0xE0E2,
        "sensors": 0xE51E,
        "slideshow": 0xE41B,
        "stop": 0xE047,
        "stop_circle": 0xEF71,
        "tune": 0xE429,
        "upload_file": 0xE9FC,
        "visibility": 0xE8F4,
        "visibility_off": 0xE8F5,
        "warning": 0xF083,
        "web_asset": 0xE069,
        "wifi": 0xE63E,
    ]

    var body: some View {
        Text(String(Character(UnicodeScalar(Self.codigos[nome] ?? 0xE88E) ?? "?")))
            .font(fonte)
            .frame(width: tamanho, height: tamanho)
            .accessibilityHidden(true)
    }

    private var fonte: Font {
        if let nsFont = M3Fontes.fonte(M3Fontes.familiaDeIcones, tamanho: tamanho,
                                       eixos: ["FILL": preenchido ? 1 : 0, "wght": peso, "opsz": min(48, max(20, tamanho))]) {
            return Font(nsFont)
        }
        return .system(size: tamanho * 0.8)
    }
}

// MARK: - Camada de estado (hover e clique)

/// Véu de 8% no hover e 10% no clique, da cor do conteúdo — a "state layer" do Material.
struct M3CamadaDeEstado: ViewModifier {
    let cor: Color
    let formato: AnyShape
    let pressionado: Bool
    @State private var sobre = false

    func body(content: Content) -> some View {
        content
            .overlay(formato.fill(cor.opacity(pressionado ? 0.10 : sobre ? 0.08 : 0)))
            .onHover { sobre = $0 }
            .animation(M3.Mola.efeito, value: sobre)
            .animation(M3.Mola.efeito, value: pressionado)
    }
}

// MARK: - Botão de ícone

enum M3VarianteDoIcone { case padrao, tonal, preenchido, perigo }

/// Botão de ícone do M3 Expressive: redondo; quando selecionado, fica preenchido e ganha
/// cantos menores (o "shape morph" dos botões de alternância).
struct M3BotaoDeIcone: View {
    let icone: String
    var variante: M3VarianteDoIcone = .tonal
    var tamanho: CGFloat = 48
    var selecionado = false
    var contador: Int? = nil
    var contadorNeutro = false
    var ajuda: String = ""
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            M3Icone(nome: icone, tamanho: tamanho * 0.46, preenchido: selecionado)
        }
        .buttonStyle(Estilo(variante: variante, tamanho: tamanho, selecionado: selecionado))
        .overlay(alignment: .topTrailing) {
            if let contador, contador > 0 {
                M3Contador(valor: contador, neutro: contadorNeutro)
                    .offset(x: 4, y: -2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(M3.Mola.rapida, value: contador ?? 0)
        .help(ajuda)
        .accessibilityLabel(ajuda)
    }

    struct Estilo: ButtonStyle {
        let variante: M3VarianteDoIcone
        let tamanho: CGFloat
        let selecionado: Bool
        @Environment(\.isEnabled) private var ativo

        func makeBody(configuration: Configuration) -> some View {
            let (fundo, frente) = cores
            let raio = selecionado ? tamanho * 0.3 : tamanho / 2
            let forma = RoundedRectangle(cornerRadius: raio, style: .continuous)
            return configuration.label
                .foregroundColor(frente)
                .frame(width: tamanho, height: tamanho)
                .background(forma.fill(fundo))
                .modifier(M3CamadaDeEstado(cor: frente, formato: AnyShape(forma), pressionado: configuration.isPressed))
                .contentShape(forma)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(ativo ? 1 : 0.38)
                .animation(M3.Mola.rapida, value: configuration.isPressed)
                .animation(M3.Mola.padrao, value: selecionado)
        }

        private var cores: (Color, Color) {
            if selecionado { return (M3.primary, M3.onPrimary) }
            switch variante {
            case .padrao: return (.clear, M3.onSurfaceVariant)
            case .tonal: return (M3.surfaceContainerHighest, M3.onSurface)
            case .preenchido: return (M3.primary, M3.onPrimary)
            case .perigo: return (M3.danger, M3.onDanger)
            }
        }
    }
}

// MARK: - Botão comum (pílula)

enum M3VarianteDoBotao { case preenchido, tonal, texto, perigo, contorno }

struct M3Botao: View {
    let titulo: String
    var icone: String? = nil
    var variante: M3VarianteDoBotao = .preenchido
    var altura: CGFloat = 40
    var larguraMinima: CGFloat = 0
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 8) {
                if let icone { M3Icone(nome: icone, tamanho: altura >= 48 ? 22 : 18, preenchido: true) }
                Text(titulo).font(M3Tipo.fonte(tamanho: altura >= 48 ? 16 : 14, peso: 500))
            }
            .padding(.horizontal, altura >= 48 ? 24 : 16)
            .frame(minWidth: larguraMinima)
            .frame(height: altura)
        }
        .buttonStyle(Estilo(variante: variante))
    }

    struct Estilo: ButtonStyle {
        let variante: M3VarianteDoBotao
        @Environment(\.isEnabled) private var ativo

        func makeBody(configuration: Configuration) -> some View {
            let (fundo, frente, borda) = cores
            let forma = Capsule(style: .continuous)
            return configuration.label
                .foregroundColor(frente)
                .background(forma.fill(fundo))
                .overlay(forma.stroke(borda, lineWidth: borda == .clear ? 0 : 1))
                .modifier(M3CamadaDeEstado(cor: frente, formato: AnyShape(forma), pressionado: configuration.isPressed))
                .contentShape(forma)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(ativo ? 1 : 0.38)
                .animation(M3.Mola.rapida, value: configuration.isPressed)
        }

        private var cores: (Color, Color, Color) {
            switch variante {
            case .preenchido: return (M3.primary, M3.onPrimary, .clear)
            case .tonal: return (M3.secondaryContainer, M3.onSecondaryContainer, .clear)
            case .texto: return (.clear, M3.primary, .clear)
            case .perigo: return (M3.danger, M3.onDanger, .clear)
            case .contorno: return (.clear, M3.primary, M3.outlineVariant)
            }
        }
    }
}

// MARK: - Contador (badge)

struct M3Contador: View {
    let valor: Int
    /// Neutro para quantidades (alunos, arquivos); vermelho só para o que pede atenção.
    var neutro = false

    var body: some View {
        Text(valor > 99 ? "99+" : "\(valor)")
            .font(M3Tipo.fonte(tamanho: 11, peso: 600).monospacedDigit())
            .foregroundColor(neutro ? M3.onSecondaryContainer : .white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(neutro ? M3.secondaryContainer : M3.danger))
            .overlay(Capsule().stroke(M3.surface, lineWidth: 2))
    }
}

// MARK: - Superfície com cantos grandes (cartões e painéis)

extension View {
    func m3Superficie(_ cor: Color = M3.surfaceContainer, canto: CGFloat = M3.Canto.extraGrande) -> some View {
        background(RoundedRectangle(cornerRadius: canto, style: .continuous).fill(cor))
            .clipShape(RoundedRectangle(cornerRadius: canto, style: .continuous))
    }
}
