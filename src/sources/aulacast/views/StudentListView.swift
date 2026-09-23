import SwiftUI

/// Painel de alunos: quem está na aula, quem está com ela à vista e quem levantou a mão (SRP).
/// No desenho da lista de Pessoas do Meet: avatar com as iniciais, nome e uma linha de apoio;
/// quem está com a mão levantada sobe para o topo, na ordem em que levantou.
public struct StudentListView: View {
    @ObservedObject var clientManager: ClientManagerService
    @ObservedObject var viewModel: MainViewModel
    @State private var copiado = false

    public init(clientManager: ClientManagerService, viewModel: MainViewModel) {
        self.clientManager = clientManager
        self.viewModel = viewModel
    }

    public var body: some View {
        if clientManager.identifiedClients.isEmpty {
            vazio
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // O que importa saber de relance: quantos estão de fato com a aula à vista.
                HStack(spacing: 8) {
                    M3Icone(nome: "visibility", tamanho: 18, preenchido: true)
                        .foregroundColor(M3.tertiary)
                    Text(resumoDePresenca)
                        .m3(.labelLarge)
                        .foregroundColor(M3.onSurfaceVariant)
                }
                .padding(.horizontal, 24)
                .help("Olho aberto: com a aula à vista. Olho cortado: conectado, mas em outra janela ou aba.")

                if maos > 0 {
                    HStack(spacing: 8) {
                        M3Icone(nome: "back_hand", tamanho: 18, preenchido: true)
                            .foregroundColor(M3.atencao)
                        Text(maos == 1 ? "1 mão levantada" : "\(maos) mãos levantadas")
                            .m3(.labelLarge)
                            .foregroundColor(M3.onSurface)
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                }

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(alunos) { aluno in
                            linha(aluno)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .animation(M3.Mola.padrao, value: alunos.map(\.id))
                }
            }
            .padding(.top, 4)
            .animation(M3.Mola.padrao, value: maos)
        }
    }

    private var alunos: [ConnectedClient] { clientManager.identifiedClientsInListOrder }
    private var maos: Int { clientManager.handRaisedCount }

    private func linha(_ aluno: ConnectedClient) -> some View {
        HStack(spacing: 16) {
            AvatarDeIniciais(nome: aluno.name)
                .opacity(aluno.isWatching ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 0) {
                Text(aluno.name)
                    .m3(.bodyLarge)
                    .foregroundColor(M3.onSurface)
                    .lineLimit(1)
                Text(aluno.isWatching ? "Com a aula à vista" : "Em outra janela ou aba")
                    .m3(.bodyMedium)
                    .foregroundColor(M3.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if aluno.isHandRaised {
                // A mão é o próprio botão de abaixá-la, como no Meet: o professor atende o
                // aluno e tira o pedido da fila com um clique.
                M3BotaoDeIcone(
                    icone: "back_hand",
                    variante: .atencao,
                    tamanho: 36,
                    iconePreenchido: true,
                    ajuda: "Abaixar a mão"
                ) { viewModel.lowerHand(clientId: aluno.id) }
                .transition(.scale.combined(with: .opacity))
            }
            M3Icone(nome: aluno.isWatching ? "visibility" : "visibility_off", tamanho: 20, preenchido: aluno.isWatching)
                .foregroundColor(aluno.isWatching ? M3.tertiary : M3.outline)
                .help(aluno.ipAddress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Ninguém entrou ainda: o que fazer e o atalho para isso (como o "Adicionar pessoas"
    /// do Meet, com o botão de copiar o link).
    private var vazio: some View {
        VStack(spacing: 14) {
            M3Icone(nome: "group", tamanho: 44)
                .foregroundColor(M3.onSurfaceVariant)
            Text("Ninguém entrou ainda")
                .m3(.titleMedium)
                .foregroundColor(M3.onSurface)
            Text("Peça à turma para digitar no navegador:")
                .m3(.bodyMedium)
                .foregroundColor(M3.onSurfaceVariant)
            Text(viewModel.displayAddress)
                .font(M3Tipo.fonte(tamanho: 22, peso: 500).monospacedDigit())
                .foregroundColor(M3.onSurface)
                .textSelection(.enabled)
            M3Botao(titulo: copiado ? "Link copiado" : "Copiar link", icone: copiado ? "check" : "content_copy", variante: .tonal) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.serverURLString, forType: .string)
                copiado = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiado = false }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Avatar circular com as iniciais, na cor de contêiner escolhida pelo nome (cada aluno
/// fica sempre com a mesma cor), como os avatares sem foto do Google.
struct AvatarDeIniciais: View {
    let nome: String

    private static let paleta: [(Color, Color)] = [
        (Color.dynamic(light: 0xD3E3FD, dark: 0x0842A0), Color.dynamic(light: 0x041E49, dark: 0xD3E3FD)),
        (Color.dynamic(light: 0xC4EED0, dark: 0x0F5223), Color.dynamic(light: 0x072711, dark: 0xC4EED0)),
        (Color.dynamic(light: 0xFFDF99, dark: 0x5C4300), Color.dynamic(light: 0x261A00, dark: 0xFFDF99)),
        (Color.dynamic(light: 0xFFDAD6, dark: 0x8C1D18), Color.dynamic(light: 0x410002, dark: 0xFFDAD6)),
        (Color.dynamic(light: 0xE8DEF8, dark: 0x4A4458), Color.dynamic(light: 0x1D192B, dark: 0xE8DEF8)),
        (Color.dynamic(light: 0xC2E7FF, dark: 0x004A77), Color.dynamic(light: 0x001D35, dark: 0xC2E7FF))
    ]

    var body: some View {
        let (fundo, frente) = Self.paleta[indice]
        Text(iniciais)
            .m3(.titleMedium)
            .foregroundColor(frente)
            .frame(width: 40, height: 40)
            .background(Circle().fill(fundo))
            .accessibilityHidden(true)
    }

    private var iniciais: String {
        let partes = nome.split(separator: " ").filter { !$0.isEmpty }
        let letras = [partes.first, partes.count > 1 ? partes.last : nil].compactMap { $0?.first }
        return String(letras).uppercased()
    }

    /// Soma estável dos caracteres (o hashValue do Swift muda a cada execução).
    private var indice: Int {
        nome.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) } % Self.paleta.count
    }
}
