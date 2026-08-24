import SwiftUI

/// Tela de solicitação da permissão "Gravação de Tela" (SRP).
public struct ScreenRecordingPermissionView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    public init(onOpenSettings: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .frame(width: 58, height: 58)

                Image(systemName: "rectangle.inset.filled.badge.record")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text("Libere a Gravação de Tela")
                .font(.title3)
                .bold()

            Text("O AulaCast precisa da permissão \u{201C}Gravação de Tela\u{201D} para capturar o monitor ou uma janela e transmitir aos alunos. Nada sai da rede local.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Ajustes do Sistema › Privacidade e Segurança › **Gravação de Tela** › ativar **AulaCast**")
                .font(.caption)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(9)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.secondary.opacity(0.2))
            )

            HStack(spacing: 10) {
                Button("Depois", action: onDismiss)
                    .buttonStyle(.acOutline(height: 38, expands: true, cornerRadius: 9, horizontalPadding: 0))

                Button("Abrir Ajustes do Sistema", action: onOpenSettings)
                    .buttonStyle(.acFilled(AC.accent, height: 38, expands: true, cornerRadius: 9, horizontalPadding: 0))
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
    }
}
