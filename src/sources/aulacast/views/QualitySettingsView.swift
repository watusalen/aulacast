import SwiftUI

/// Configurações da transmissão: resolução, taxa de quadros, nome e chat (SRP).
///
/// Cada ajuste vale no instante em que é feito, inclusive com a aula no ar, então não há
/// o que confirmar — por isso não existe botão de "Concluído". A janela é um popover
/// ancorado na engrenagem: fecha clicando fora ou com Esc, como manda o padrão do macOS.
public struct QualitySettingsView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var captureService: ScreenCaptureService

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

            VStack(alignment: .leading, spacing: 6) {
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

                Text(viewModel.isChatEnabled
                     ? "Os alunos podem escrever para você."
                     : "O campo de mensagem fica inativo na tela dos alunos na hora.")
                    .font(.system(size: 12))
                    .foregroundColor(AC.textSecondary)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
