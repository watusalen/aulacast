import SwiftUI

/// Aba de alunos do painel lateral: quem está conectado e quem está com a aula à vista (SRP).
public struct StudentListView: View {
    @ObservedObject var clientManager: ClientManagerService
    let serverURLString: String

    public init(clientManager: ClientManagerService, serverURLString: String) {
        self.clientManager = clientManager
        self.serverURLString = serverURLString
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // O título ("Alunos") fica na aba do painel; aqui, o que importa saber de relance:
            // quantos estão de fato com a aula à vista.
            if !clientManager.identifiedClients.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 11))
                        .foregroundColor(AC.liveGreen)
                    Text(resumoDePresenca)
                        .font(.system(size: 12))
                        .foregroundColor(AC.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .help("Olho aberto: com a aula à vista. Olho cortado: conectado, mas em outra janela ou aba.")

                Divider()
            }

            if clientManager.identifiedClients.isEmpty {
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle().stroke(AC.textSecondary, lineWidth: 2).frame(width: 18, height: 18)
                        Circle().stroke(AC.textSecondary, lineWidth: 2).frame(width: 24, height: 24)
                        Circle().stroke(AC.textSecondary, lineWidth: 2).frame(width: 18, height: 18)
                    }
                    .opacity(0.35)

                    Text("Nenhum aluno conectado")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AC.textPrimary)

                    Text("Peça à turma para digitar no navegador o endereço mostrado no alto da janela.")
                        .font(.system(size: 13))
                        .foregroundColor(AC.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AC.panelBG)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(clientManager.identifiedClients) { client in
                            VStack(spacing: 0) {
                                HStack(spacing: 12) {
                                    // Olho aberto = está com a aula à vista; olho cortado =
                                    // conectado, mas com a janela minimizada ou em outra aba.
                                    Image(systemName: client.isWatching ? "eye.fill" : "eye.slash.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(client.isWatching ? AC.liveGreen : AC.textTertiary)
                                        .frame(width: 16)
                                        .help(client.isWatching ? "Assistindo à transmissão" : "Conectado, mas não está com a aula à vista")

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(client.name)
                                            .font(.system(size: 15))
                                            .foregroundColor(client.isWatching ? AC.textPrimary : AC.textSecondary)
                                            .lineLimit(1)

                                        Text(client.ipAddress)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(AC.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)

                                Divider()
                            }
                        }
                    }
                }
                .background(AC.panelBG)
            }
        }
    }

    private var resumoDePresenca: String {
        let total = clientManager.identifiedClients.count
        let vendo = clientManager.watchingCount
        if vendo == total {
            return total == 1 ? "1 aluno, com a aula à vista" : "Todos os \(total) com a aula à vista"
        }
        return "\(vendo) de \(total) com a aula à vista"
    }
}
