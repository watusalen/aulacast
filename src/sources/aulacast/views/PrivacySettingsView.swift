import SwiftUI

/// Painel "Ocultar apps": marca aplicativos para nunca aparecer na transmissão do monitor
/// inteiro — mesmo em tela cheia — do mesmo jeito que o AulaCast já se esconde sozinho.
///
/// Só faz diferença com "Monitor Completo" como fonte: uma janela específica já mostra só
/// ela, então não há nada em volta para esconder.
public struct PrivacySettingsView: View {
    @ObservedObject var captureService: ScreenCaptureService

    public init(captureService: ScreenCaptureService) {
        self.captureService = captureService
    }

    /// Um app por linha, mesmo com várias janelas abertas — dedup pelo bundle identifier.
    /// Sem nome de app ou sem bundle identifier (Central de Controle etc.) já saiu no
    /// `ShareableContentFetcher`, então não sobra ruído aqui.
    private var appsParaEscolher: [AppParaOcultar] {
        var vistos = Set<String>()
        var apps: [AppParaOcultar] = []
        for fonte in captureService.availableSources where fonte.type == .window {
            guard let bundleID = fonte.ownerBundleID, vistos.insert(bundleID).inserted else { continue }
            apps.append(AppParaOcultar(bundleID: bundleID, nome: SourceNaming.title(fonte)))
        }
        return apps.sorted { $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ocultar apps da transmissão")
                .m3(.titleLarge)
                .foregroundColor(M3.onSurface)

            HStack(alignment: .top, spacing: 10) {
                M3Icone(nome: "info", tamanho: 18)
                Text(
                    "Vale só para \"Monitor Completo\". Os apps marcados somem do que a turma "
                    + "vê mesmo em tela cheia, igual ao próprio AulaCast."
                )
                .m3(.bodySmall)
            }
            .foregroundColor(M3.onSurfaceVariant)

            if appsParaEscolher.isEmpty {
                Text("Nenhum outro app aberto no momento.")
                    .m3(.bodyMedium)
                    .foregroundColor(M3.onSurfaceVariant)
            } else {
                VStack(spacing: 4) {
                    ForEach(appsParaEscolher) { app in
                        linhaDoApp(app)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func linhaDoApp(_ app: AppParaOcultar) -> some View {
        HStack {
            Text(app.nome)
                .m3(.bodyMedium)
                .foregroundColor(M3.onSurface)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: bindingParaOcultar(app.bundleID))
                .toggleStyle(.switch)
                .tint(M3.primary)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private func bindingParaOcultar(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { captureService.hiddenBundleIDs.contains(bundleID) },
            set: { oculto in
                if oculto {
                    captureService.hiddenBundleIDs.insert(bundleID)
                } else {
                    captureService.hiddenBundleIDs.remove(bundleID)
                }
            }
        )
    }
}

private struct AppParaOcultar: Identifiable {
    let bundleID: String
    let nome: String
    var id: String { bundleID }
}
