import SwiftUI

/// Painel lateral de alunos conectados e notificações de dúvidas (SRP).
public struct StudentListView: View {
    @ObservedObject var clientManager: ClientManagerService
    let serverURLString: String

    public init(clientManager: ClientManagerService, serverURLString: String) {
        self.clientManager = clientManager
        self.serverURLString = serverURLString
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Alunos Conectados (\(clientManager.clients.count))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AC.textPrimary)

                // Quantos estão realmente com a aula à vista, e não só conectados.
                if !clientManager.clients.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 10))
                        Text("\(clientManager.watchingCount)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(AC.liveGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AC.liveGreen.opacity(0.14)))
                    .help("Alunos com a transmissão à vista")
                }

                Spacer()
                if clientManager.handRaisedCount > 0 {
                    Text("Dúvidas: \(clientManager.handRaisedCount)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AC.handOrange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AC.handOrange.opacity(0.16)))
                        .overlay(Capsule().stroke(AC.handOrange.opacity(0.4), lineWidth: 1))
                }
            }
            .padding(14)
            .background(AC.panelBG)

            Divider()

            if clientManager.clients.isEmpty {
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

                    Text("Peça à turma para abrir o navegador e acessar o endereço exibido no lado esquerdo da tela.")
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
                        ForEach(clientManager.clients) { client in
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
                                            .font(.system(size: 15, weight: client.isHandRaised ? .semibold : .regular))
                                            .foregroundColor(client.isWatching ? AC.textPrimary : AC.textSecondary)
                                            .lineLimit(1)

                                        Text(client.ipAddress)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(AC.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    // Quem abaixa a mão é o próprio aluno, pelo botão dele.
                                    // Aqui é só leitura, para o professor saber quem chamou.
                                    if client.isHandRaised {
                                        Image(systemName: "hand.raised.fill")
                                            .font(.system(size: 13))
                                            .foregroundColor(AC.handOrange)
                                            .help("Levantou a mão")
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(client.isHandRaised ? AC.handOrange.opacity(0.07) : Color.clear)

                                Divider()
                            }
                        }
                    }
                }
                .background(AC.panelBG)
            }
        }
    }
}
