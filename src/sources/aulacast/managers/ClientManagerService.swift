import Foundation

/// Gerenciador com responsabilidade unica de armazenar e processar a lista de alunos e as
/// mãos levantadas (SRP).
public final class ClientManagerService: ObservableObject {
    @Published public private(set) var clients: [ConnectedClient] = []

    public init() {}

    /// Registra o aluno preservando o id da conexão. É esse id que o servidor usa depois
    /// para identificar o aluno e tirá-lo da lista — gerar um id novo aqui faria a busca
    /// nunca casar.
    public func addOrUpdateClient(_ client: ConnectedClient) {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index].name = client.name
            clients[index].ipAddress = client.ipAddress
        } else {
            clients.append(client)
        }
    }

    public func addOrUpdateClient(name: String, ip: String = "192.168.1.X") {
        if let index = clients.firstIndex(where: { $0.name == name }) {
            if !ip.contains("X") {
                clients[index].ipAddress = ip
            }
        } else {
            // Quem chega por aqui já vem com nome de verdade, então já conta como identificado.
            addOrUpdateClient(ConnectedClient(name: name, ipAddress: ip, hasIdentified: true))
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
    }

    /// Registra o nome que o aluno informou na entrada da aula.
    public func identify(clientId: String, name: String) {
        guard let index = clients.firstIndex(where: { $0.id == clientId }) else { return }
        guard !name.isEmpty else { return }
        clients[index].name = name
        clients[index].hasIdentified = true
    }

    /// Levanta ou abaixa a mão de um aluno já conectado, identificado pela conexão.
    ///
    /// Quem levanta é o próprio aluno; quem abaixa pode ser ele ou o professor. Levantar de
    /// novo com a mão já no alto (a página repete a mensagem) mantém o lugar na fila: senão
    /// o aluno que esperava há mais tempo iria para o fim da lista.
    public func setHandRaised(clientId: String, isRaised: Bool, at instante: Date = Date()) {
        guard let index = clients.firstIndex(where: { $0.id == clientId }) else { return }
        if isRaised {
            guard clients[index].handRaisedAt == nil else { return }
            clients[index].handRaisedAt = instante
        } else {
            guard clients[index].handRaisedAt != nil else { return }
            clients[index].handRaisedAt = nil
        }
    }

    /// Marca se a aba do aluno está visível na tela dele.
    public func setWatching(clientId: String, isWatching: Bool) {
        guard let index = clients.firstIndex(where: { $0.id == clientId }) else { return }
        clients[index].isWatching = isWatching
    }

    /// Alunos que já disseram o nome — são estes que o professor vê na lista.
    ///
    /// Toda conexão entra primeiro como "Aluno-x.y" e só vira aluno de verdade depois do
    /// IDENTIFY. Mostrar todas punha na lista (e na contagem de quem assiste) quem teve o
    /// nome recusado ou nunca chegou a se identificar.
    public var identifiedClients: [ConnectedClient] {
        clients.filter { $0.hasIdentified }
    }

    /// A lista na ordem em que o professor a vê: primeiro quem está com a mão levantada, de
    /// quem levantou antes para quem levantou depois (a vez de cada um, como no Meet), e em
    /// seguida os demais na ordem de chegada.
    public var identifiedClientsInListOrder: [ConnectedClient] {
        let alunos = identifiedClients
        let comMao = alunos
            .filter { $0.isHandRaised }
            .sorted { ($0.handRaisedAt ?? .distantFuture) < ($1.handRaisedAt ?? .distantFuture) }
        return comMao + alunos.filter { !$0.isHandRaised }
    }

    /// Quantos alunos identificados estão com a mão levantada.
    ///
    /// Calculado na hora, e não guardado à parte: um contador mantido em paralelo já ficou
    /// pendurado com a mão de quem tinha saído da aula.
    public var handRaisedCount: Int {
        identifiedClients.filter { $0.isHandRaised }.count
    }

    /// Quantos alunos estão de fato com a transmissão à vista.
    public var watchingCount: Int {
        identifiedClients.filter { $0.isWatching }.count
    }
}