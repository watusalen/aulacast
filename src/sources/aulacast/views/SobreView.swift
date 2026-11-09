import SwiftUI
import AppKit

/// Página "Sobre o AulaCast": ícone, nome, versão, o que o app faz e os créditos.
/// Abre numa janela própria, pelo menu do app (`SobreJanela.mostrar()`).
struct SobreView: View {
    /// "Versão 1.0.0 (1)". Rodando por `swift run` não há bundle, então não há versão a mostrar.
    private var versao: String {
        let info = Bundle.main.infoDictionary
        guard let numero = info?["CFBundleShortVersionString"] as? String else { return "Versão de desenvolvimento" }
        if let build = info?["CFBundleVersion"] as? String { return "Versão \(numero) (\(build))" }
        return "Versão \(numero)"
    }

    private var copyright: String? {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    }

    var body: some View {
        VStack(spacing: 0) {
            cabecalho
            corpo
        }
        .frame(width: 420)
        .background(M3.surface)
    }

    // MARK: - Cabeçalho

    private var cabecalho: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .accessibilityHidden(true)

            Text("AulaCast")
                .m3(.displaySmall)
                .foregroundColor(M3.onSurface)

            Text(versao)
                .m3(.labelMedium)
                .foregroundColor(M3.onPrimaryContainer)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(M3.surface.opacity(0.75)))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [M3.primaryContainer, M3.surface], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Corpo

    private var corpo: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Transmissão de tela em rede local")
                    .m3(.titleMedium)
                    .foregroundColor(M3.onSurface)
                Text("O anfitrião transmite a própria tela, e os participantes assistem pelo navegador, tudo dentro da mesma rede.")
                    .m3(.bodyMedium)
                    .foregroundColor(M3.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                destaque(icone: "wifi_off", titulo: "Funciona sem internet", detalhe: "Tudo trafega pela rede local")
                destaque(icone: "web_asset", titulo: "Nada para instalar", detalhe: "Os participantes assistem direto no navegador")
                destaque(icone: "group", titulo: "Presença, chat e arquivos", detalhe: "Lista de participantes, mão levantada e compartilhamento")
            }

            Rectangle().fill(M3.outlineVariant).frame(height: 1)

            VStack(spacing: 4) {
                Text("Projeto acadêmico do IFPI — Campus Piripiri")
                Text("Fontes: Google Sans Flex (SIL OFL 1.1) e Material Symbols Rounded (Apache 2.0)")
                if let copyright { Text(copyright) }
            }
            .m3(.labelSmall)
            .foregroundColor(M3.onSurfaceVariant)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
    }

    /// Uma linha de destaque: ícone num círculo tonal, título e detalhe.
    private func destaque(icone: String, titulo: String, detalhe: String) -> some View {
        HStack(spacing: 14) {
            M3Icone(nome: icone, tamanho: 22)
                .foregroundColor(M3.onSecondaryContainer)
                .frame(width: 44, height: 44)
                .background(Circle().fill(M3.secondaryContainer))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).m3(.titleSmall).foregroundColor(M3.onSurface)
                Text(detalhe).m3(.bodySmall).foregroundColor(M3.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: M3.Canto.grande, style: .continuous).fill(M3.surfaceContainer))
        .accessibilityElement(children: .combine)
    }
}

/// A janela do "Sobre": criada uma vez e reaproveitada. É AppKit de propósito: uma cena
/// `Window` do SwiftUI pode abrir sozinha ao iniciar o app, e aqui ela só abre pelo menu.
@MainActor
public enum SobreJanela {
    private static var janela: NSWindow?

    public static func mostrar() {
        if let existente = janela {
            existente.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hospedeiro = NSHostingController(rootView: SobreView())
        let nova = NSWindow(contentViewController: hospedeiro)
        nova.title = "Sobre o AulaCast"
        nova.styleMask = [.titled, .closable, .fullSizeContentView]
        nova.titlebarAppearsTransparent = true
        nova.titleVisibility = .hidden
        nova.isMovableByWindowBackground = true
        nova.isReleasedWhenClosed = false
        nova.setContentSize(hospedeiro.view.fittingSize)
        nova.center()
        janela = nova
        nova.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
