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
}
