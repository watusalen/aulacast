import Foundation
import AulaCastCore

/// Testes CORE da lista por conexão e do palpite de navegador (ADR-005). Em arquivo próprio
/// para não pesar na função `main`.
@MainActor
func testesConexoesPorPessoa(_ assertTest: (Bool, String) -> Void) async {
    print("\n--- [39] Conexões por pessoa e navegador detectado ---")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func depois(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    let casos: [(String, String, String?)] = [
        ("Safari Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15", "Safari no Mac"),
        ("Chrome Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", "Chrome no Mac"),
        ("Firefox Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0", "Firefox no Windows"),
        ("Edge Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0", "Edge no Windows"),
        ("Chrome Android", "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36", "Chrome no Android"),
        ("Safari iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1", "Safari no iPhone"),
        ("Chrome iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0.6099.119 Mobile/15E148 Safari/604.1", "Chrome no iPhone"),
        ("Safari iPad", "Mozilla/5.0 (iPad; CPU OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1", "Safari no iPad"),
        ("vazio", "", nil),
        ("lixo", "lixo qualquer 123", nil),
        ("navegador sem aparelho", "Mozilla/5.0 Firefox/121.0", "Firefox")
    ]
    for (nome, ua, esperado) in casos {
        assertTest(NavegadorDetectado.descrever(userAgent: ua) == esperado, "Navegador: \(nome)")
    }

    let ua = casos[0].1
    do {
        let l = AttendanceLedger(clock: { t0 })
        l.setAccruing(true, at: t0)
        l.connected(clientId: "a", ip: "10.0.0.1", at: t0)
        l.identified(clientId: "a", name: "Ana", at: t0)
        l.connected(clientId: "b", ip: "10.0.0.1", at: depois(30))
        l.identified(clientId: "b", name: "Ana B", at: depois(30))
        let id = l.pessoaId(clientId: "a")!
        var r = l.resumo(pessoaId: id, agora: depois(60))
        assertTest(r?.conexoes.count == 2 && r?.conexoes.allSatisfy { $0.ativa } == true, "Conexões: duas abertas = dois registros ativos")
        assertTest(r?.conexoes.first?.descricao == nil, "Conexões: sem ENV ainda, sem descrição")
        l.environment(clientId: "a", userAgent: ua)
        l.environment(clientId: "b", userAgent: "lixo")
        r = l.resumo(pessoaId: id, agora: depois(60))
        assertTest(r?.conexoes.first?.descricao == "Safari no Mac" && r?.conexoes.last?.descricao == nil,
                   "Conexões: ENV depois da identificação preenche a descrição")
        l.disconnected(clientId: "a", at: depois(90))
        r = l.resumo(pessoaId: id, agora: depois(100))
        let a = r?.conexoes.first
        assertTest(a?.ativa == false && a?.saiuAs == depois(90) && a?.descricao == "Safari no Mac" && r?.conexoes.last?.ativa == true,
                   "Conexões: quem sai fica como inativo com hora de saída")
        assertTest(a?.entrouAs == t0 && r?.conexoes.last?.entrouAs == depois(30), "Conexões: hora de entrada de cada uma")
        assertTest(r?.naAula == 100 && r?.aVista == 100 && r?.nomes.count == 2 && r?.desconexoes == 0,
                   "Conexões: tempos e nomes seguem iguais")
    }
    do {
        let l = AttendanceLedger(clock: { t0 })
        for i in 0..<(AttendanceLedger.maxNomes + 3) {
            l.connected(clientId: "c\(i)", ip: "10.0.0.9", at: depois(Double(i)))
            l.identified(clientId: "c\(i)", name: "N", at: depois(Double(i)))
            if i == 5 { l.disconnected(clientId: "c5", at: depois(6)) }
        }
        let r = l.resumo(pessoaId: l.pessoaId(clientId: "c0")!, agora: depois(100))
        assertTest(r?.conexoes.count == AttendanceLedger.maxNomes && r?.conexoes.contains { $0.id == "c5" } == false,
                   "Conexões: teto de 20, sai primeiro a mais antiga já encerrada")
    }

    // Reconexões do mesmo navegador não criam linhas novas (dois navegadores que reconectam
    // várias vezes continuam sendo duas linhas).
    do {
        let uaChrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        let l = AttendanceLedger(clock: { t0 })
        l.setAccruing(true, at: t0)
        func entrar(_ id: String, _ ua: String, _ s: TimeInterval) {
            l.connected(clientId: id, ip: "10.0.0.5", at: depois(s))
            l.identified(clientId: id, name: "Ana", at: depois(s))
            l.environment(clientId: id, userAgent: ua)
        }
        entrar("s1", ua, 0)           // Safari
        entrar("c1", uaChrome, 5)     // Chrome ao mesmo tempo
        for k in 0..<3 {              // as duas abas perdem a conexão e voltam, três vezes
            let base = TimeInterval(60 + k * 60)
            l.disconnected(clientId: k == 0 ? "s1" : "s\(k + 1)", at: depois(base))
            l.disconnected(clientId: k == 0 ? "c1" : "c\(k + 1)", at: depois(base))
            entrar("s\(k + 2)", ua, base + 2)
            entrar("c\(k + 2)", uaChrome, base + 3)
        }
        let id = l.pessoaId(clientId: "s4")!
        let r = l.resumo(pessoaId: id, agora: depois(300))
        assertTest(r?.conexoes.count == 2, "Reconexões: 2 navegadores que reconectam 3 vezes seguem sendo 2 linhas (\(r?.conexoes.count ?? -1))")
        assertTest(r?.conexoes.allSatisfy { $0.ativa } == true, "Reconexões: as duas linhas voltam a ficar ativas")
        assertTest(r?.conexoes.map { $0.entrouAs }.sorted() == [depois(0), depois(5)], "Reconexões: cada linha conserva a hora da primeira entrada")
        assertTest(Set(r?.conexoes.compactMap { $0.descricao } ?? []) == ["Safari no Mac", "Chrome no Mac"], "Reconexões: Safari e Chrome continuam separados")
        assertTest(r?.desconexoes == 3, "Reconexões: o contador de desconexões e voltas segue contando (\(r?.desconexoes ?? -1))")
    }
    // Duas abas abertas ao mesmo tempo no mesmo navegador NÃO se fundem (só registros encerrados são reaproveitados).
    do {
        let l = AttendanceLedger(clock: { t0 })
        l.setAccruing(true, at: t0)
        for (k, id) in ["x1", "x2"].enumerated() {
            l.connected(clientId: id, ip: "10.0.0.6", at: depois(TimeInterval(k)))
            l.identified(clientId: id, name: "Beto", at: depois(TimeInterval(k)))
            l.environment(clientId: id, userAgent: ua)
        }
        let r = l.resumo(pessoaId: l.pessoaId(clientId: "x1")!, agora: depois(10))
        assertTest(r?.conexoes.count == 2 && r?.conexoes.allSatisfy { $0.ativa } == true, "Reconexões: duas abas ao mesmo tempo seguem sendo duas linhas ativas")
    }

    // Conectada e olhando x conectada em outra aba: o registro da conexão acompanha a visibilidade.
    do {
        let l = AttendanceLedger(clock: { t0 })
        l.setAccruing(true, at: t0)
        l.connected(clientId: "v1", ip: "10.0.0.7", visible: true, at: t0)
        l.identified(clientId: "v1", name: "Carla", at: t0)
        l.connected(clientId: "v2", ip: "10.0.0.7", visible: false, at: depois(5))
        l.identified(clientId: "v2", name: "Carla", at: depois(5))
        let id = l.pessoaId(clientId: "v1")!
        func registro(_ cid: String) -> ConexaoDaPessoa? { l.resumo(pessoaId: id, agora: depois(100))?.conexoes.first { $0.id == cid } }
        assertTest(registro("v1")?.visivel == true && registro("v2")?.visivel == false,
                   "Visibilidade: cada conexão nasce com o estado da sua aba")
        l.visibility(clientId: "v1", visible: false, at: depois(20))
        assertTest(registro("v1")?.visivel == false && registro("v1")?.ativa == true,
                   "Visibilidade: sair da aba deixa a conexão ativa, só não mais à vista")
        l.visibility(clientId: "v2", visible: true, at: depois(30))
        assertTest(registro("v2")?.visivel == true && registro("v1")?.visivel == false,
                   "Visibilidade: voltar à aba volta a ficar à vista, sem mexer na outra conexão")
        // Antes de o ENV chegar, a visibilidade já vale; o tempo "vendo" da pessoa não muda por causa disto.
        let r = l.resumo(pessoaId: id, agora: depois(100))
        assertTest(r?.naAula == 100, "Visibilidade: o tempo na aula segue contando (\(r?.naAula ?? -1))")
    }
}
