import Foundation
import AulaCastCore

/// Testes CORE (sem portas) da lista de alunos por pessoa (RF-20, US-14): duas conexões do
/// mesmo IP são uma linha só.
@MainActor
func testesListaPorPessoa(_ assertTest: (Bool, String) -> Void) async {
    print("\n--- [39] Lista de alunos: uma linha por pessoa ---")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func c(_ id: String, _ nome: String, ip: String, vendo: Bool = true, mao: TimeInterval? = nil, ident: Bool = true) -> ConnectedClient {
        ConnectedClient(id: id, name: nome, ipAddress: ip, connectedAt: t0, hasIdentified: ident,
                        isWatching: vendo, handRaisedAt: mao.map { t0.addingTimeInterval($0) })
    }
    let l = AttendanceLedger(clock: { t0 })
    func conectar(_ id: String, _ ip: String, _ nome: String) {
        l.connected(clientId: id, ip: ip, at: t0)
        l.identified(clientId: id, name: nome, at: t0.addingTimeInterval(1))
    }
    conectar("a1", "10.0.0.1", "Ana"); conectar("b1", "10.0.0.2", "Bia"); conectar("a2", "10.0.0.1", "Ana")
    let pid: (String) -> String? = { l.pessoaId(clientId: $0) }

    let todos = [c("a1", "Ana", ip: "10.0.0.1", vendo: false), c("b1", "Bia", ip: "10.0.0.2"),
                 c("a2", "Ana", ip: "10.0.0.1"), c("x", "Aluno-1.2", ip: "10.0.0.9", ident: false)]
    let linhas = agruparPorPessoa(clientes: todos, pessoaId: pid)
    assertTest(linhas.count == 2, "Duas conexões da mesma pessoa viram uma linha (sem a não identificada)")
    assertTest(linhas[0].conexoes == 2 && linhas[0].conexoesIds == ["a1", "a2"], "A linha da pessoa conta 2 conexões")
    assertTest(linhas[0].aVista, "À vista se ALGUMA conexão estiver visível")
    assertTest(linhas.map(\.nome) == ["Ana", "Bia"], "Ordem de chegada mantida com a segunda conexão")

    let semVista = agruparPorPessoa(clientes: [c("a1", "Ana", ip: "10.0.0.1", vendo: false), c("a2", "Ana", ip: "10.0.0.1", vendo: false)], pessoaId: pid)
    assertTest(semVista.count == 1 && !semVista[0].aVista, "Sem vista quando nenhuma conexão está visível")

    // Mão em qualquer conexão; a mais antiga vale; quem levantou vai ao topo.
    let comMao = agruparPorPessoa(clientes: [c("a1", "Ana", ip: "10.0.0.1"), c("b1", "Bia", ip: "10.0.0.2", mao: 50),
                                             c("a2", "Ana", ip: "10.0.0.1", mao: 10)], pessoaId: pid)
    assertTest(comMao.map(\.nome) == ["Ana", "Bia"] && comMao[0].maoLevantadaEm == t0.addingTimeInterval(10), "Mão em qualquer conexão sobe a pessoa, pela hora mais antiga")
    assertTest(comMao[0].conexoesComMao == ["a2"], "O botão abaixa só as conexões com a mão levantada")

    // Fechar uma conexão mantém a linha e o estado; fechar a última tira.
    let aposUma = agruparPorPessoa(clientes: [c("b1", "Bia", ip: "10.0.0.2"), c("a2", "Ana", ip: "10.0.0.1", mao: 10)], pessoaId: pid)
    assertTest(aposUma.count == 2 && aposUma[0].nome == "Ana" && aposUma[0].conexoes == 1 && aposUma[0].maoLevantada, "Fechar uma conexão mantém a linha e a mão")
    let aposTodas = agruparPorPessoa(clientes: [c("b1", "Bia", ip: "10.0.0.2")], pessoaId: pid)
    assertTest(aposTodas.map(\.nome) == ["Bia"], "Fechar a última conexão remove a linha")

    // Contagens por pessoa.
    assertTest(linhas.count == 2 && comMao.filter(\.maoLevantada).count == 2 && linhas.filter(\.aVista).count == 2,
               "Contagens (alunos, mãos, à vista) são por pessoa, não por conexão")

    // Segundo navegador, mesmo IP, nome DIFERENTE: uma linha, com o nome mais recente.
    let l2 = AttendanceLedger(clock: { t0 })
    l2.connected(clientId: "p1", ip: "10.0.0.5", at: t0); l2.identified(clientId: "p1", name: "Carla", at: t0)
    l2.connected(clientId: "p2", ip: "10.0.0.5", at: t0.addingTimeInterval(30)); l2.identified(clientId: "p2", name: "Carla Souza", at: t0.addingTimeInterval(30))
    let dois = agruparPorPessoa(
        clientes: [c("p1", "Carla", ip: "10.0.0.5"), c("p2", "Carla Souza", ip: "10.0.0.5")],
        pessoaId: { l2.pessoaId(clientId: $0) },
        nomeDaPessoa: { l2.resumo(pessoaId: $0)?.nome }
    )
    assertTest(dois.count == 1 && dois[0].conexoes == 2 && dois[0].nome == "Carla Souza", "Nome diferente no mesmo IP: uma linha, com o nome mais recente")
}
