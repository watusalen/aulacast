import SwiftUI

/// Configurações de qualidade da transmissão: resolução, taxa de quadros e chat (SRP).
public struct QualitySettingsView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var captureService: ScreenCaptureService
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: MainViewModel, captureService: ScreenCaptureService) {
        self.viewModel = viewModel
        self.captureService = captureService
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Qualidade da Transmissão")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(AC.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Resolução")
                    .font(.system(size: 13))
                    .foregroundColor(AC.textSecondary)

                ACSegmentedPicker(
                    options: VideoResolution.allCases.map { ($0, $0.rawValue) },
                    selection: $captureService.resolution
                )

                Text("720p é recomendado para PCs antigos do laboratório.")
                    .font(.system(size: 12))
                    .foregroundColor(AC.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Taxa de quadros")
                    .font(.system(size: 13))
                    .foregroundColor(AC.textSecondary)

                ACSegmentedPicker(
                    options: [(15, "15 fps"), (30, "30 fps")],
                    selection: $captureService.frameRate
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Seu nome (opcional)")
                    .font(.system(size: 13))
                    .foregroundColor(AC.textSecondary)

                TextField("Como aparecer para a turma", text: $viewModel.professorName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AC.inputBG))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AC.border, lineWidth: 1))

                Text("Em branco, os alunos veem apenas \u{201C}Professor\u{201D}.")
                    .font(.system(size: 12))
                    .foregroundColor(AC.textSecondary)
            }

            Divider()

            HStack {
                Text("Permitir chat dos alunos")
                    .font(.system(size: 14))
                    .foregroundColor(AC.textPrimary)
                Spacer()
                Toggle("", isOn: $viewModel.isChatEnabled)
                    .toggleStyle(.switch)
                    .tint(AC.liveGreen)
                    .labelsHidden()
            }

            Divider()

            HStack {
                Spacer()
                Button("Concluído") {
                    dismiss()
                }
                .buttonStyle(.acFilled(AC.accent, height: 34, cornerRadius: 8, horizontalPadding: 18))
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(AC.panelBG)
    }
}
