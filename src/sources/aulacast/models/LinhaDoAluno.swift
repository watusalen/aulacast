import Foundation

/// Uma linha da lista de alunos: uma PESSOA, não uma conexão (RF-20). Quem abre um segundo
/// navegador ou aba no mesmo IP continua sendo a mesma linha.
public struct LinhaDoAluno: Identifiable, Equatable {
    public let pessoaId: String
    public var id: String { pessoaId }
    public let nome: String
    public let conexoesIds: [String]
    public var conexoes: Int { conexoesIds.count }
    /// Alguma conexão com a aula à vista.
    public let aVista: Bool
    /// A mais antiga entre as mãos levantadas, para manter a vez na fila; `nil` com todas abaixadas.
    public let maoLevantadaEm: Date?
    public var maoLevantada: Bool { maoLevantadaEm != nil }
    /// Conexões desta pessoa com a mão levantada (as que o botão "Abaixar a mão" deve baixar).
    public let conexoesComMao: [String]
    public let ip: String
}

/// Agrupa as conexões identificadas por pessoa. Ordem: mãos levantadas primeiro, pela hora;
/// depois a ordem de chegada da primeira conexão de cada pessoa (estável quando uma segunda
/// conexão abre ou fecha). Conexão sem pessoa no ledger vira uma pessoa própria. O(n log n).
/// - Parameter nomeDaPessoa: nome mais recente da pessoa; sem ele vale o da primeira conexão.
public func agruparPorPessoa(
    clientes: [ConnectedClient],
    pessoaId: (String) -> String?,
    nomeDaPessoa: (String) -> String? = { _ in nil }
) -> [LinhaDoAluno] {
    var ordem: [String] = []
    var grupos: [String: [ConnectedClient]] = [:]
    for c in clientes where c.hasIdentified {
        let chave = pessoaId(c.id) ?? "conexao:\(c.id)"
        if grupos[chave] == nil { ordem.append(chave) }
        grupos[chave, default: []].append(c)
    }
    let linhas = ordem.map { chave -> LinhaDoAluno in
        let cs = grupos[chave]!
        let maos = cs.filter { $0.isHandRaised }
        return LinhaDoAluno(
            pessoaId: chave,
            nome: nomeDaPessoa(chave) ?? cs[0].name,
            conexoesIds: cs.map(\.id),
            aVista: cs.contains { $0.isWatching },
            maoLevantadaEm: maos.compactMap(\.handRaisedAt).min(),
            conexoesComMao: maos.map(\.id),
            ip: cs[0].ipAddress
        )
    }
    let comMao = linhas.filter(\.maoLevantada).sorted { $0.maoLevantadaEm! < $1.maoLevantadaEm! }
    return comMao + linhas.filter { !$0.maoLevantada }
}
