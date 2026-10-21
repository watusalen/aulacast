import Foundation
import Network
import AulaCastCore

/// Testes CORE (sem portas, sem esperas longas) de identidade/nomes no ledger, perfil, chamada em
/// CSV e do gate das métricas permanentes (RF-20, RF-21, ADR-005, ADR-006). Em arquivo próprio
/// para não pesar na função `main`.
@MainActor
func testesPerfilEChamada(_ assertTest: (Bool, String) -> Void) async {
    print("\n--- [38] Perfil, nomes usados, chamada em CSV e métricas permanentes ---")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000) // 14/11/2023 22:13:20 UTC
    func depois(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: Ledger: identidade estável e nomes
    do {
        let l = AttendanceLedger(clock: { t0 })
        l.setAccruing(true, at: t0)
        l.connected(clientId: "c1", ip: "10.0.0.1", at: t0)
        l.identified(clientId: "c1", name: "Ana", at: t0)
        let id = l.pessoaId(clientId: "c1")
        assertTest(id != nil && l.pessoaId(nome: "  ANA ") == id, "Ledger: pessoaId por clientId e por nome (sem caixa/espaços)")
        l.identified(clientId: "c1", name: "Ana Maria", at: depois(60))
        let r = l.resumo(pessoaId: id!, agora: depois(60))
        assertTest(r?.nomes.count == 2 && r?.nomes[1].viaIP == true && r?.nomes[0].viaIP == false,
                   "Ledger: segundo nome no mesmo IP entra como viaIP")
        assertTest(r?.nomes[1].atual == true && r?.nomes[0].atual == false && r?.nome == "Ana Maria", "Ledger: só o nome mais recente é o atual")
        assertTest(l.pessoaId(nome: "ana") == id && l.pessoaId(nome: "ANA MARÍA") == id, "Ledger: busca por nome antigo e por acento")
        assertTest(l.pessoaId(nome: "Desconhecida") == nil, "Ledger: nome desconhecido não resolve")
        l.disconnected(clientId: "c1", at: depois(120))
        let apos = l.resumo(pessoaId: id!, agora: depois(130))
        assertTest(apos != nil && apos?.conectada == false && apos?.ultimaSaidaAs == depois(120), "Ledger: resumo por pessoaId funciona depois de sair")
        assertTest(l.resumo(clientId: "c1") == nil, "Ledger: API por clientId segue nil depois de sair")
        assertTest(l.pessoaId(nome: "Ana") == id, "Ledger: nome continua resolvendo depois de sair")

        // Homônimo conectado de outro IP: quem chegou antes é o dono do nome.
        l.connected(clientId: "c2", ip: "10.0.0.2", at: depois(200))
        l.identified(clientId: "c2", name: "Bia", at: depois(200))
        l.connected(clientId: "c3", ip: "10.0.0.3", at: depois(210))
        l.identified(clientId: "c3", name: "Bia", at: depois(210))
        assertTest(l.pessoaId(clientId: "c3") != l.pessoaId(clientId: "c2") && l.pessoaId(nome: "bia") == l.pessoaId(clientId: "c2"),
                   "Ledger: homônimo conectado continua pessoa separada; o primeiro é dono do nome")

        // Fusão por nome: o id antigo continua resolvendo para quem ficou.
        l.connected(clientId: "c4", ip: "10.0.0.4", at: depois(300))
        let idAntigo = l.pessoaId(clientId: "c4")!
        l.identified(clientId: "c4", name: "ana maria", at: depois(310))
        assertTest(l.resumo(pessoaId: idAntigo, agora: depois(320))?.pessoaId == id, "Ledger: id de pessoa fundida aponta para a sobrevivente")
        assertTest(l.pessoaId(clientId: "c4") == id, "Ledger: reconexão com o mesmo nome volta à mesma pessoa")

        // todos: só identificados.
        l.connected(clientId: "c5", ip: "10.0.0.5", at: depois(330))
        assertTest(l.todos(agora: depois(340)).count == 3 && l.todos(agora: depois(340)).allSatisfy { $0.nome != nil },
                   "Ledger: todos() lista só quem tem nome (e junta reconexões)")
    }
    do {
        let l = AttendanceLedger(clock: { t0 })
        l.connected(clientId: "c", ip: "1.1.1.1", at: t0)
        for i in 1...25 { l.identified(clientId: "c", name: "N\(i)", at: depois(Double(i))) }
        let r = l.resumo(clientId: "c")
        assertTest(r?.nomes.count == AttendanceLedger.maxNomes && r?.nomes.first?.nome == "N6" && r?.nomes.last?.atual == true,
                   "Ledger: teto de 20 nomes descarta os mais antigos")
    }

    // MARK: CSV exato
    let l = AttendanceLedger(clock: { t0 })
    l.setAccruing(true, at: t0)
    l.connected(clientId: "a1", ip: "10.0.0.1", at: t0)
    l.identified(clientId: "a1", name: "Ana", at: t0)
    l.connected(clientId: "e1", ip: "10.0.0.2", at: depois(60))
    l.identified(clientId: "e1", name: "Élio", at: depois(60))
    l.visibility(clientId: "e1", visible: false, at: depois(120))
    l.connected(clientId: "x1", ip: "10.0.0.3", at: t0)
    l.identified(clientId: "x1", name: "=cmd;x", at: t0)
    l.disconnected(clientId: "x1", at: t0)
    l.disconnected(clientId: "a1", at: depois(600))
    l.connected(clientId: "a2", ip: "10.0.0.9", at: depois(700))
    l.identified(clientId: "a2", name: "ANA", at: depois(700))
    l.disconnected(clientId: "a2", at: depois(760))
    l.connected(clientId: "n1", ip: "10.0.0.4", at: depois(10)) // sem nome: não entra
    let fim = depois(800)
    let resumos = l.todos(agora: fim)
    let utc = TimeZone(identifier: "UTC")!
    let csv = ChamadaCSV.gerar(resumos: resumos, fimDaSessao: fim, fuso: utc)
    let esperado = "\u{FEFF}Nome;Presença;Entrou;Saiu;Minutos na aula;Minutos com a aula à vista;Percentual à vista\r\n"
        + "\"'=cmd;x\";Presente;14/11/2023 22:13;14/11/2023 22:13;0,0;0,0;0,0\r\n"
        + "ANA;Presente;14/11/2023 22:13;14/11/2023 22:26;11,0;11,0;100,0\r\n"
        + "Élio;Presente;14/11/2023 22:14;14/11/2023 22:26;12,3;1,0;8,1\r\n"
    assertTest(csv == Data(esperado.utf8), "CSV: bytes exatos (BOM, cabeçalho, CRLF, ';', vírgula, ordem, fusão, aspas, fórmula, sem anônimo)")
    if csv != Data(esperado.utf8) { print(String(decoding: csv, as: UTF8.self)) }
    assertTest(Array(csv.prefix(3)) == [0xEF, 0xBB, 0xBF], "CSV: começa com BOM UTF-8")
    assertTest(ChamadaCSV.campo("a\"b") == "\"a\"\"b\"" && ChamadaCSV.campo("l1\nl2") == "\"l1\nl2\"" && ChamadaCSV.campo("@x") == "'@x"
               && ChamadaCSV.campo("+1") == "'+1" && ChamadaCSV.campo("-1") == "'-1" && ChamadaCSV.campo("\tx") == "'\tx" && ChamadaCSV.campo("Ana") == "Ana",
               "CSV: aspas RFC 4180 e neutralização de = + - @ tab")

    // MARK: Escritor
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("chamada-teste-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let pasta = base.appendingPathComponent("Chamadas")
    assertTest(ChamadaWriter.salvar(resumos: [], fimDaSessao: fim, pasta: pasta, fuso: utc) == .vazia
               && !FileManager.default.fileExists(atPath: pasta.path), "Escritor: sessão sem identificados não cria arquivo nem pasta")
    let r1 = ChamadaWriter.salvar(resumos: resumos, fimDaSessao: fim, pasta: pasta, fuso: utc)
    let r2 = ChamadaWriter.salvar(resumos: resumos, fimDaSessao: fim, pasta: pasta, fuso: utc)
    let r3 = ChamadaWriter.salvar(resumos: resumos, fimDaSessao: fim, pasta: pasta, fuso: utc)
    func nome(_ r: ResultadoDaChamada) -> String? { if case .salva(let u, _) = r { return u.lastPathComponent } else { return nil } }
    assertTest(nome(r1) == "chamada-2023-11-14-2226.csv" && nome(r2) == "chamada-2023-11-14-2226-2.csv" && nome(r3) == "chamada-2023-11-14-2226-3.csv",
               "Escritor: nome pela hora local e sufixo -2, -3 sem sobrescrever")
    if case .salva(let u, let n) = r1 { assertTest(n == 3 && (try? Data(contentsOf: u)) == csv, "Escritor: conteúdo gravado é o CSV e conta 3 alunos") }
    let arquivoComum = base.appendingPathComponent("arquivo.txt")
    try? Data("x".utf8).write(to: arquivoComum)
    assertTest(ChamadaWriter.salvar(resumos: resumos, fimDaSessao: fim, pasta: arquivoComum.appendingPathComponent("sub"), fuso: utc) == .falhou,
               "Escritor: pasta impossível vira .falhou, sem travar")

    // MARK: ViewModel: perfil e aviso da chamada
    let vm = MainViewModel(captureService: FakeCaptureService(), encoderService: FakeEncoder(), serverService: FakeServer(),
                           advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity(),
                           permission: FakePermission(concedida: true), hostnameService: FakeHostname())
    vm.pastaDasChamadas = pasta
    vm.ledger.connected(clientId: "v1", ip: "10.1.1.1")
    vm.ledger.identified(clientId: "v1", name: "Caio")
    vm.ledger.identified(clientId: "v1", name: "Caio Souza")
    vm.abrirPerfil(nome: "Zé Ninguém")
    assertTest(vm.alunoAberto == nil, "VM: abrirPerfil(nome:) ignora nome desconhecido")
    vm.abrirPerfil(nome: "caio")
    let idCaio = vm.ledger.pessoaId(clientId: "v1")
    assertTest(vm.alunoAberto != nil && vm.alunoAberto == idCaio, "VM: abrirPerfil(nome:) resolve nome antigo da pessoa")
    vm.didClientDisconnect(clientId: "v1")
    try? await Task.sleep(nanoseconds: 100_000_000)
    assertTest(vm.alunoAberto == idCaio && vm.ledger.resumo(pessoaId: idCaio!) != nil, "VM: alunoAberto continua após o aluno desconectar")
    vm.alunoAberto = nil
    vm.abrirPerfil(clientId: "v1")
    assertTest(vm.alunoAberto == nil, "VM: abrirPerfil(clientId:) de conexão que saiu não faz nada (o perfil abre pela linha ativa)")
    let resultadoVM = vm.salvarChamada(em: fim)
    assertTest({ if case .salva = resultadoVM { return true } else { return false } }()
               && vm.avisoDaChamada?.texto == "Chamada salva (1 aluno)" && vm.avisoDaChamada?.arquivo != nil, "VM: chamada salva mostra o aviso com o arquivo")
    vm.avisoDaChamada = nil
    assertTest(vm.salvarChamada(em: fim) == .vazia && vm.avisoDaChamada == nil, "VM: a chamada é salva uma vez por sessão")
    let vmRuim = MainViewModel(captureService: FakeCaptureService(), encoderService: FakeEncoder(), serverService: FakeServer(),
                               advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity(),
                               permission: FakePermission(concedida: true), hostnameService: FakeHostname())
    vmRuim.pastaDasChamadas = arquivoComum.appendingPathComponent("sub")
    vmRuim.ledger.connected(clientId: "w", ip: "1.2.3.4")
    vmRuim.ledger.identified(clientId: "w", name: "Dani")
    vmRuim.salvarChamada(em: fim)
    assertTest(vmRuim.avisoDaChamada?.texto == "Não foi possível salvar a chamada" && vmRuim.avisoDaChamada?.arquivo == nil, "VM: falha de disco vira aviso, sem travar")

    // MARK: Métricas permanentes: dois modos (injetável)
    let conexao = NWConnection(host: "127.0.0.1", port: 9, using: .tcp) // nunca iniciada: sem rede
    for console in [true, false] {
        let rotulo = console ? "build de depuração" : "build release"
        let h = WebSocketHandlerService()
        h.consoleDeMetricas = console
        let boas = h.payloadDeBoasVindas()
        assertTest(boas["metricas"] as? String == "true", "Métricas (\(rotulo)): CONNECTED sempre manda metricas=true")
        assertTest((boas["debugConsole"] as? String == "true") == console, "Métricas (\(rotulo)): debugConsole só com o console ativo")
        h.processClientJSON("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Lia\"}}", clientId: "m1", fallbackName: "x", connection: conexao)
        h.processClientJSON("{\"type\":\"METRICS\",\"payload\":{\"rota\":\"H.264\",\"fps\":28,\"mbps\":2.1,\"dropped\":0,\"lagMs\":100}}",
                            clientId: "m1", fallbackName: "x", connection: conexao)
        h.processClientJSON("{\"type\":\"ENV\",\"payload\":{\"userAgent\":\"UA\",\"plataforma\":\"Mac\",\"telaLarg\":1000,\"telaAlt\":800,\"dpr\":2,\"idioma\":\"pt-BR\"}}",
                            clientId: "m1", fallbackName: "x", connection: conexao)
        assertTest(h.metricas.relatorio(clientId: "m1") != nil && h.metricas.ambiente(clientId: "m1") != nil,
                   "Métricas (\(rotulo)): METRICS e ENV do navegador são aceitos")
        h.processClientJSON("{\"type\":\"METRICS\",\"payload\":{\"rota\":\"MJPEG\",\"fps\":10}}", clientId: "intruso", fallbackName: "x", connection: conexao)
        assertTest(h.metricas.relatorio(clientId: "intruso") == nil, "Métricas (\(rotulo)): METRICS sem IDENTIFY continua ignorado")
        let linhas = h.broadcastMetricsTable(resumo: ["alunos": 0])
        assertTest(linhas.count == 1, "Métricas (\(rotulo)): as linhas por aluno (arquivo e terminal) existem nos dois modos")
    }
}
