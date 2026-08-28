import Foundation

/// Gerenciador com responsabilidade unica de armazenar e processar a lista de alunos e duvidas (SRP).
public final class ClientManagerService: ObservableObject {
    @Published public private(set) var clients: [ConnectedClient] = []
    @Published public private(set) var handRaisedCount: Int = 0

    public init() {}

    /// Registra o aluno preservando o id da conexão. É esse id que o servidor usa depois
    /// para levantar/abaixar a mão — gerar um id novo aqui faria a busca nunca casar.
    public func addOrUpdateClient(_ client: ConnectedClient) {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index].name = client.name
            clients[index].ipAddress = client.ipAddress
            clients[index].isHandRaised = client.isHandRaised
        } else {
            clients.append(client)
        }
        recalculateHandRaises()
    }

    public func addOrUpdateClient(name: String, ip: String = "192.168.1.X", isHandRaised: Bool) {
        if let index = clients.firstIndex(where: { $0.name == name }) {
            clients[index].isHandRaised = isHandRaised
            if !ip.contains("X") {
                clients[index].ipAddress = ip
            }
            recalculateHandRaises()
        } else {
            addOrUpdateClient(ConnectedClient(name: name, ipAddress: ip, isHandRaised: isHandRaised))
        }
    }

    /// Remove o aluno pelo id da conexão.
    ///
    /// Havia aqui uma segunda tentativa por nome, para o caso de o id não casar. Como quem
    /// chama é sempre a queda da conexão, que só conhece o id, essa busca nunca acertava o
    /// alvo pretendido — mas podia acertar outro: numa turma com dois "Ana" (ou dois alunos
    /// ainda sem se identificar, todos chamados "Aluno-…"), o nome não distingue ninguém e
    /// quem saía da lista era o primeiro homônimo encontrado.
    public func removeClient(id: String) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        clients.remove(at: index)
        recalculateHandRaises()
    }

    /// Levanta ou abaixa a mão de um aluno já conectado, identificado pela conexão.
    /// Só o próprio aluno aciona isto (o professor apenas observa), então o nome exibido
    /// é atualizado de passagem, caso ele tenha se identificado depois de entrar.
    public func setHandRaised(clientId: String, displayName: String, isRaised: Bool) {
        guard let index = clients.firstIndex(where: { $0.id == clientId }) else { return }

        clients[index].isHandRaised = isRaised
        if !displayName.isEmpty {
            clients[index].name = displayName
        }
        recalculateHandRaises()
    }

    /// Registra o nome que o aluno informou na entrada da aula.
    public func identify(clientId: String, name: String) {
        guard let index = clients.firstIndex(where: { $0.id == clientId }) else { return }
        guard !name.isEmpty else { return }
        clients[index].name = name
        clients[index].hasIdentified = true
    }

    /// Marca se a aba do aluno está visível na tela dele.
    public func setWatching(clientId: String, isWatching: Bool) {
        guard let index = clients.firstIndex(where: { $0.id == clientId }) else { return }
        clients[index].isWatching = isWatching
    }

    /// Quantos alunos estão de fato com a transmissão à vista.
    public var watchingCount: Int {
        clients.filter { $0.isWatching }.count
    }

    private func recalculateHandRaises() {
        handRaisedCount = clients.filter { $0.isHandRaised }.count
    }
}