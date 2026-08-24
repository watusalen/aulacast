import SwiftUI

/// Menu flutuante na barra de menus superior do macOS (MenuBarExtra).
public struct MenuBarView: View {
    @EnvironmentObject private var viewModel: MainViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AulaCast — Transmissão Local")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(AC.textPrimary)

            Divider()

            VStack(spacing: 7) {
                statRow(label: "Status", value: viewModel.isStreaming ? "Transmitindo" : "Parado", color: viewModel.isStreaming ? AC.liveGreen : AC.offlineRed)
                statRow(label: "Alunos Conectados", value: "\(viewModel.clientManager.clients.count)", color: AC.textPrimary)
                if viewModel.clientManager.handRaisedCount > 0 {
                    statRow(label: "Dúvidas Pendentes", value: "\(viewModel.clientManager.handRaisedCount)", color: AC.handOrange)
                }
            }

            Divider()

            VStack(spacing: 8) {
                Button(action: {
                    if viewModel.isStreaming {
                        viewModel.stopStream()
                    } else {
                        viewModel.startStream()
                    }
                }) {
                    Text(viewModel.isStreaming ? "Parar Transmissão" : "Iniciar Transmissão")
                }
                .buttonStyle(.acFilled(viewModel.isStreaming ? AC.stopRed : AC.accent, height: 34, expands: true, cornerRadius: 8, horizontalPadding: 0))

                Button("Encerrar AulaCast") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.acOutline(height: 34, expands: true, cornerRadius: 8, horizontalPadding: 0))
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func statRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(AC.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
        }
    }
}
