import Foundation
import AulaCastCore

/// Seção 37: arquivo de métricas rico (legenda, linha de aluno plana, contrato do navegador,
/// atribuição por IP, teto, amostrador). Fica em arquivo próprio para não pesar na compilação
/// da função `main`, que já é enorme.
@MainActor
func testesMetricasRicas(_ assertTest: (Bool, String) -> Void) async {
        // (37) Arquivo de métricas rico: legenda, linhas planas, contrato do navegador, atribuição por IP.
        print("\n--- [37/37] Métricas ricas: legenda, aluno plano, contrato, IP, teto, amostrador ---")
        do {
            // Conta da perda e dos Mbps por conexão (função pura sobre duas fotografias).
            var antes = StreamSnapshot(), depois = StreamSnapshot()
            antes.quadrosPorAluno = [1: 0, 2: 0, 3: 10]; depois.quadrosPorAluno = [1: 60, 2: 40, 3: 10]
            depois.ipPorAluno = [1: "10.0.0.1", 2: "10.0.0.2", 3: "10.0.0.3"]; antes.ipPorAluno = depois.ipPorAluno
            antes.bytesPorAluno = [1: 0, 2: 0]; depois.bytesPorAluno = [1: 1_250_000, 2: 250_000]
            antes.estourosPorAluno = [:]; depois.estourosPorAluno = [2: 3]
            let medidas = StreamAttribution.medidas(antes, e: depois, segundos: 2).sorted { $0.ip < $1.ip }
            assertTest(medidas.count == 3 && medidas[0].fps == 30 && abs(medidas[0].mbps - 5) < 1e-9 && medidas[0].quadros == 60,
                       "Medida por conexão: 60 quadros e 1,25 MB em 2 s = 30 fps e 5 Mbps")
            assertTest(medidas[1].estouros == 3 && medidas[2].fps == 0, "Medida por conexão: estouros e conexão parada")
            assertTest(StreamAttribution.medidas(antes, e: depois, segundos: 0).isEmpty, "Medida: intervalo zero não divide")

            // Ligação por IP, incluindo IP compartilhado.
            let conexoes = [
                MedidaDeConexao(ip: "10.0.0.1", fps: 30, mbps: 2, quadros: 60, estouros: 0),
                MedidaDeConexao(ip: "10.0.0.2", fps: 20, mbps: 1, quadros: 40, estouros: 1),
                MedidaDeConexao(ip: "10.0.0.2", fps: 25, mbps: 2, quadros: 50, estouros: 0)
            ]
            let ligados = StreamAttribution.atribuir(alunos: ["a": "10.0.0.1", "b": "10.0.0.2", "c": "10.0.0.2", "d": "10.0.0.9"], conexoes: conexoes)
            assertTest(ligados["a"] == MedidaDoServidor(fps: 30, mbps: 2, quadros: 60, estouros: 0, compartilhado: false),
                       "Atribuição por IP: aluno com IP próprio")
            assertTest(ligados["b"]?.compartilhado == true && ligados["c"]?.compartilhado == true
                       && ligados["b"]?.fps == 25 && ligados["b"]?.mbps == 3 && ligados["b"]?.quadros == 90 && ligados["b"]?.estouros == 1,
                       "Atribuição por IP: IP compartilhado soma Mbps/quadros, usa o maior fps e marca srvCompartilhado")
            assertTest(ligados["d"] == nil, "Atribuição por IP: aluno sem conexão de vídeo fica sem srv")

            // Linha de aluno plana.
            let rel = StudentMetricsReport(rota: "H.264", fps: 29, mbps: 2, dropped: 1, lagMs: 120, droppedTotal: 7, rttMs: 15,
                                           bufferS: 0.4, playbackRate: 1.02, visivel: true)
            let linhaPlana = MetricsFileLogger.linhaDeAluno(nome: "Ana", relatorio: rel, reportadoHa: 1.5, srv: ligados["a"])
            let esperadosAluno: Set<String> = ["nome", "rota", "fps", "mbps", "dropped", "droppedTotal", "lagMs", "rttMs", "bufferS",
                                               "playbackRate", "visivel", "reportadoHa", "srvFps", "srvMbps", "srvQuadros", "srvEstouros", "srvCompartilhado"]
            assertTest(Set(linhaPlana.keys) == esperadosAluno, "Linha aluno: exatamente os campos planos da legenda")
            assertTest(linhaPlana.values.allSatisfy { !($0 is [Any]) && !($0 is [String: Any]) }, "Linha aluno: nenhum valor aninhado")
            assertTest(linhaPlana["droppedTotal"] as? Int == 7 && linhaPlana["srvFps"] as? Double == 30 && linhaPlana["srvCompartilhado"] as? Bool == false,
                       "Linha aluno: valores do navegador e do servidor")
            let semDados = MetricsFileLogger.linhaDeAluno(nome: "Bia", relatorio: nil, reportadoHa: nil, srv: nil)
            assertTest(semDados["fps"] is NSNull && semDados["srvFps"] is NSNull, "Linha aluno: sem medição vira null")

            // Arquivo: legenda primeiro, tudo JSON válido, tSeg e t em toda linha, teto e 'truncado'.
            let pasta = FileManager.default.temporaryDirectory.appendingPathComponent("aulacast-ricas-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: pasta) }
            var relogio = Date(timeIntervalSince1970: 2_000_000)
            let log = MetricsFileLogger(diretorio: pasta, limiteBytes: 4_000, agora: { relogio })
            log.iniciar(porta: 8181, contexto: ["modeloMac": "Mac-Teste", "nucleos": 8])
            relogio = relogio.addingTimeInterval(2)
            log.registrarAmostra(alunos: 1, h264: 1, mjpeg: 0, telaFps: 30, mediaFps: 24, minFps: 24, mbpsTotal: 3,
                                 estourosDeFila: 0, pedidosDeQuadroChave: 1, bytesTotais: 1000, cpuPct: 12.5, memMB: 80,
                                 pausada: false, wifi: ["rssi": -60, "ruido": -90, "taxaTxMbps": 300.0, "canal": 36],
                                 linhasDeAluno: [linhaPlana])
            for i in 0..<200 { log.registrar(tipo: "seek", dados: ["nome": "Ana", "i": i]) }
            log.encerrar(tempos: ["Ana": ["naAulaS": 100.0, "aVistaS": 90.0, "aVistaPct": 90.0, "saidas": 1, "maiorTrechoS": 60.0]])
            let texto = (try? String(contentsOf: log.arquivo!, encoding: .utf8)) ?? ""
            let objs: [[String: Any]] = texto.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            assertTest(objs.count == texto.split(separator: "\n").count, "Arquivo: toda linha escrita é JSON válido")
            assertTest(objs.first?["tipo"] as? String == "legenda", "Arquivo: a 1ª linha é a legenda")
            let leg = objs.first ?? [:]
            assertTest(leg["esquema"] as? Int == 1 && (leg["campos"] as? [String: Any])?["aluno"] != nil
                       && (leg["campos"] as? [String: Any])?["amostra"] != nil && (leg["graficos"] as? [String])?.count == 9
                       && (leg["promptSugerido"] as? String)?.contains("pandas") == true,
                       "Legenda: versão do esquema, campos por tipo, 9 gráficos (8 + comparação de configurações) e o prompt em português")
            assertTest(objs.allSatisfy { $0["tipo"] is String && $0["tSeg"] as? Double != nil && $0["t"] is String },
                       "Arquivo: toda linha tem tipo, tSeg e t")
            assertTest(objs.dropFirst().first?["tipo"] as? String == "inicio" && objs[1]["modeloMac"] as? String == "Mac-Teste" && objs[1]["porta"] as? Int == 8181,
                       "Arquivo: 'inicio' traz o contexto e a porta")
            let amostraRica = objs.first { $0["tipo"] as? String == "amostra" }
            assertTest(amostraRica?["tSeg"] as? Double == 2 && amostraRica?["cpuPct"] as? Double == 12.5 && amostraRica?["memMB"] as? Double == 80
                       && amostraRica?["bytesTotais"] as? Int == 1000 && amostraRica?["pausada"] as? Bool == false
                       && (amostraRica?["wifi"] as? [String: Any])?["rssi"] as? Int == -60 && amostraRica?["aVista"] as? Int == 1,
                       "Amostra: tSeg, CPU, memória, bytes, pausada, aVista e Wi-Fi")
            assertTest(abs((amostraRica?["perdaEstimadaPct"] as? Double ?? -1) - 20) < 1e-9, "Amostra: perda estimada 30 vs 24 fps = 20%")
            assertTest(objs.contains { $0["tipo"] as? String == "aluno" && $0["nome"] as? String == "Ana" && $0["rttMs"] as? Int == 15 },
                       "Arquivo: linha 'aluno' plana ao lado da amostra")
            assertTest(objs.filter { $0["tipo"] as? String == "truncado" }.count == 1 && objs.filter { $0["tipo"] as? String == "seek" }.count < 200,
                       "Teto: uma só linha 'truncado' e para de anexar")
            let fimRico = objs.last
            let resumoAna = (fimRico?["alunos"] as? [[String: Any]])?.first { $0["nome"] as? String == "Ana" }
            assertTest(fimRico?["tipo"] as? String == "fim" && fimRico?["picoAlunos"] as? Int == 1 && resumoAna?["aVistaPct"] as? Double == 90
                       && resumoAna?["fpsMedio"] as? Double == 29 && resumoAna?["quadrosDescartados"] as? Int == 7,
                       "Fim: pico, tempos do ledger e resumo por aluno (fps médio, descartados) mesmo depois do teto")
            assertTest(MetricsFileLogger.limitePadraoBytes == 64 * 1024 * 1024, "Teto padrão é 64 MB")
            assertTest(amostraRica?["blocoConfig"] as? Int == 1 && amostraRica?["resolucao"] is NSNull && amostraRica?["fpsAlvo"] is NSNull
                       && amostraRica?["taxaAlvoBps"] is NSNull && amostraRica?["fonte"] is NSNull,
                       "Config: sem provedor, os campos são null (nunca inventados) e o bloco é 1")

            // Comparação de configurações: 720p (2 amostras) e 1080p (2 amostras), com números calculados à mão.
            let pastaCfg = pasta.appendingPathComponent("cfg")
            var rc = Date(timeIntervalSince1970: 4_000_000)
            let lc = MetricsFileLogger(diretorio: pastaCfg, agora: { rc })
            lc.iniciar(porta: 8182)
            let c720 = ConfigDeCaptura(resolucao: "720p", fpsAlvo: 30, taxaAlvoBps: 1_600_000, fonte: "monitor")
            let c1080 = ConfigDeCaptura(resolucao: "1080p", fpsAlvo: 30, taxaAlvoBps: 2_500_000, fonte: "monitor")
            func amostra(_ cfg: ConfigDeCaptura, alunos: Int, mbps: Double, media: Double, minimo: Double, cpu: Double, mem: Double, est: Int, ped: Int, lag: Int) {
                let l = MetricsFileLogger.linhaDeAluno(nome: "Ana", relatorio: StudentMetricsReport(rota: "H.264", fps: media, mbps: 1, dropped: 0, lagMs: lag),
                                                       reportadoHa: 1, srv: nil)
                lc.registrarAmostra(alunos: alunos, h264: alunos, mjpeg: 0, telaFps: 30, mediaFps: media, minFps: minimo, mbpsTotal: mbps,
                                    estourosDeFila: est, pedidosDeQuadroChave: ped, cpuPct: cpu, memMB: mem, config: cfg, linhasDeAluno: [l])
            }
            rc = rc.addingTimeInterval(2); amostra(c720, alunos: 2, mbps: 4, media: 30, minimo: 28, cpu: 10, mem: 100, est: 0, ped: 1, lag: 100)
            rc = rc.addingTimeInterval(2); amostra(c720, alunos: 4, mbps: 8, media: 24, minimo: 20, cpu: 20, mem: 120, est: 1, ped: 2, lag: 200)
            rc = rc.addingTimeInterval(2); amostra(c1080, alunos: 2, mbps: 10, media: 15, minimo: 10, cpu: 40, mem: 200, est: 4, ped: 5, lag: 400)
            rc = rc.addingTimeInterval(2); amostra(c1080, alunos: 2, mbps: 14, media: 15, minimo: 12, cpu: 60, mem: 220, est: 6, ped: 8, lag: 600)
            lc.encerrar()
            let objC: [[String: Any]] = ((try? String(contentsOf: lc.arquivo!, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let amC = objC.filter { $0["tipo"] as? String == "amostra" }, alC = objC.filter { $0["tipo"] as? String == "aluno" }
            assertTest(amC.compactMap { $0["blocoConfig"] as? Int } == [1, 1, 2, 2] && alC.compactMap { $0["blocoConfig"] as? Int } == [1, 1, 2, 2],
                       "Config: a mudança de resolução incrementa blocoConfig nas linhas amostra e aluno")
            assertTest(amC[0]["resolucao"] as? String == "720p" && amC[2]["resolucao"] as? String == "1080p" && amC[2]["taxaAlvoBps"] as? Int == 2_500_000
                       && alC[3]["resolucao"] as? String == "1080p" && alC[3]["fpsAlvo"] as? Int == 30 && alC[0]["fonte"] as? String == "monitor",
                       "Config: resolucao, fpsAlvo, taxaAlvoBps e fonte aparecem em amostra e aluno")
            let pc = (objC.last?["porCfg"] as? [[String: Any]]) ?? (objC.last?["porConfiguracao"] as? [[String: Any]]) ?? []
            func n(_ i: Int, _ k: String) -> Double { (pc[i][k] as? NSNumber)?.doubleValue ?? -999 }
            assertTest(pc.count == 2 && pc[0]["resolucao"] as? String == "720p" && pc[1]["resolucao"] as? String == "1080p", "porConfiguracao: um item por bloco")
            // Bloco 1: amostras em t=2 (dt 0, 1ª da sessão) e t=4 (dt 2). Bloco 2: t=6 e t=8 (dt 2 + 2).
            assertTest(n(0, "duracaoS") == 2 && n(1, "duracaoS") == 4 && n(0, "amostras") == 2, "porConfiguracao: duração acumulada por bloco")
            assertTest(n(0, "alunosMedio") == 3 && n(0, "mbpsMedioTotal") == 6 && n(0, "mbpsMedioPorAluno") == 2 && n(0, "fpsMedio") == 27
                       && n(0, "fpsMinimoMedio") == 24 && n(0, "lagMsMedio") == 150 && n(0, "cpuMedioPct") == 15 && n(0, "memMBMedio") == 110,
                       "porConfiguracao 720p: médias à mão (alunos 3, 6 Mbps, 2 Mbps/aluno, fps 27, mín 24, lag 150, CPU 15, mem 110)")
            assertTest(abs(n(0, "perdaMediaPct") - 10) < 1e-9 && n(0, "estourosDeFila") == 1 && n(0, "pedidosDeQuadroChave") == 2,
                       "porConfiguracao 720p: perda média 10% (0% e 20%) e deltas 1 e 2")
            assertTest(n(1, "alunosMedio") == 2 && n(1, "mbpsMedioTotal") == 12 && n(1, "mbpsMedioPorAluno") == 6 && n(1, "lagMsMedio") == 500
                       && n(1, "cpuMedioPct") == 50 && n(1, "perdaMediaPct") == 50 && n(1, "estourosDeFila") == 5 && n(1, "pedidosDeQuadroChave") == 6,
                       "porConfiguracao 1080p: 12 Mbps (6 por aluno), lag 500, CPU 50, perda 50%, deltas desde o bloco anterior (5 e 6)")

            // Tempos por aluno do AttendanceLedger (alimentam o 'fim').
            var t0 = Date(timeIntervalSince1970: 3_000_000)
            let livroTempo = AttendanceLedger(clock: { t0 })
            livroTempo.setAccruing(true, at: t0)
            livroTempo.connected(clientId: "x", ip: "10.1.1.1", visible: true, at: t0)
            livroTempo.identified(clientId: "x", name: "Caio", at: t0)
            t0 = t0.addingTimeInterval(100)
            let tempos = livroTempo.temposPorNome(agora: t0)["Caio"]
            assertTest(tempos?["naAulaS"] as? Double == 100 && tempos?["aVistaS"] as? Double == 100 && tempos?["aVistaPct"] as? Double == 100,
                       "Ledger: temposPorNome traz tempo na aula, à vista e %")

            // Mudança de qualidade sem nenhum aluno (nenhuma amostra no meio): o bloco ainda sobe, uma vez por mudança.
            let pastaSem = pasta.appendingPathComponent("sem-alunos")
            var rs = Date(timeIntervalSince1970: 6_000_000)
            let ls = MetricsFileLogger(diretorio: pastaSem, agora: { rs })
            ls.iniciar(porta: 8183)
            let cA = ConfigDeCaptura(resolucao: "720p", fpsAlvo: 15, taxaAlvoBps: 1_200_000, fonte: "monitor", fpsEncoder: 15)
            let cB = ConfigDeCaptura(resolucao: "1080p", fpsAlvo: 15, taxaAlvoBps: 1_200_000, fonte: "monitor", fpsEncoder: 15)
            let cC = ConfigDeCaptura(resolucao: "1080p", fpsAlvo: 30, taxaAlvoBps: 2_500_000, fonte: "monitor", fpsEncoder: 15)
            func amostraSimples(_ c: ConfigDeCaptura) {
                ls.registrarAmostra(alunos: 1, h264: 1, mjpeg: 0, telaFps: 30, mediaFps: 30, minFps: 30, mbpsTotal: 2, estourosDeFila: 0,
                                    pedidosDeQuadroChave: 0, config: c, linhasDeAluno: [MetricsFileLogger.linhaDeAluno(nome: "Ana", relatorio: nil, reportadoHa: nil, srv: nil)])
            }
            rs = rs.addingTimeInterval(2); amostraSimples(cA)
            ls.registrar(tipo: "config", dados: ["resolucaoDe": "720p", "resolucaoPara": "1080p"])
            ls.registrar(tipo: "config", dados: ["fpsDe": 15, "fpsPara": 30])
            rs = rs.addingTimeInterval(2); amostraSimples(cC)
            rs = rs.addingTimeInterval(2); amostraSimples(cC)
            ls.encerrar()
            let objS: [[String: Any]] = ((try? String(contentsOf: ls.arquivo!, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            assertTest(objS.filter { $0["tipo"] as? String == "amostra" }.compactMap { $0["blocoConfig"] as? Int } == [1, 3, 3]
                       && objS.filter { $0["tipo"] as? String == "aluno" }.compactMap { $0["blocoConfig"] as? Int } == [1, 3, 3],
                       "Config sem alunos: dois eventos config sem amostras no meio fazem o próximo bloco ser o 3")
            assertTest(objS.filter { $0["tipo"] as? String == "config" }.count == 2 && cB.resolucao == "1080p", "Config sem alunos: os eventos config foram escritos")
            let amS = objS.filter { $0["tipo"] as? String == "amostra" }
            assertTest(amS[1]["fpsAlvo"] as? Int == 30 && amS[1]["fpsEncoder"] as? Int == 15 && amS[1]["taxaAlvoBps"] as? Int == 2_500_000,
                       "Config aplicada: fpsEncoder diferente de fpsAlvo aparece na amostra")
            let pcS = (objS.last?["porConfiguracao"] as? [[String: Any]]) ?? []
            assertTest(pcS.compactMap { $0["blocoConfig"] as? Int } == [1, 3], "porConfiguracao: usa os mesmos números de bloco das linhas")

            // Mudança de resolução e fps com a transmissão no ar, pelo view model: evento config e provedor.
            let capturaVM = FakeCaptureService()
            let servidorVM = FakeServer()
            let vmCfg = MainViewModel(captureService: capturaVM, encoderService: FakeEncoder(), serverService: servidorVM,
                                      advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity(),
                                      permission: FakePermission(concedida: true), hostnameService: FakeHostname())
            vmCfg.startStream()
            try? await Task.sleep(nanoseconds: 500_000_000)
            capturaVM.resolution = .p720
            try? await Task.sleep(nanoseconds: 300_000_000)
            capturaVM.frameRate = 15
            try? await Task.sleep(nanoseconds: 300_000_000)
            let cfgs = servidorVM.eventosDeSessao.filter { $0.tipo == "config" }
            assertTest(cfgs.count == 2 && cfgs[0].dados["resolucaoDe"] as? String == "1080p" && cfgs[0].dados["resolucaoPara"] as? String == "720p"
                       && cfgs[0].dados["fpsDe"] == nil && cfgs[1].dados["fpsDe"] as? Int == 30 && cfgs[1].dados["fpsPara"] as? Int == 15
                       && cfgs[1].dados["resolucaoDe"] == nil,
                       "Config no ar: trocar resolução e depois fps gera um evento config cada, só com o campo que mudou")
            assertTest(cfgs.allSatisfy { $0.dados["encoderAtualizado"] as? Bool == false && $0.dados["taxaAlvoBpsAplicada"] != nil },
                       "Config no ar: sem sessão do encoder, encoderAtualizado é falso e a taxa aplicada é null")
            let atual = servidorVM.provedorDeConfiguracao?()
            assertTest(atual?.resolucao == "720p" && atual?.fpsAlvo == 15 && atual?.fonte == "monitor"
                       && atual?.taxaAlvoBps == H264FrameEncoder.taxaMediaBps(largura: 1280, altura: 720, fps: 15),
                       "Config no ar: o provedor entrega a configuração nova para as próximas linhas")
            vmCfg.stopStream()

            // Contrato navegador -> servidor.
            var rel0 = Date(timeIntervalSince1970: 5_000)
            let b = StudentMetricsBook(agora: { rel0 })
            let completo: [String: Any] = ["rota": "H.264", "fps": 30, "mbps": 2, "dropped": 1, "droppedTotal": 5, "lagMs": 90, "rttMs": 12,
                                           "bufferS": 0.3, "playbackRate": 1.0, "visivel": true,
                                           "conexao": ["tipo": "4g", "downlinkMbps": 10.5, "rttMs": 50] as [String: Any]]
            assertTest(b.registrar(clientId: "c", payload: completo), "Contrato: METRICS completo é aceito")
            let guardado = b.relatorio(clientId: "c")
            assertTest(guardado?.droppedTotal == 5 && guardado?.rttMs == 12 && guardado?.bufferS == 0.3 && guardado?.visivel == true
                       && guardado?.conexao == StudentConnectionInfo(tipo: "4g", downlinkMbps: 10.5, rttMs: 50), "Contrato: campos novos guardados")
            rel0 = rel0.addingTimeInterval(2)
            assertTest(!b.registrar(clientId: "c", payload: completo.merging(["extra": 1]) { a, _ in a }), "Contrato: chave desconhecida invalida")
            assertTest(!b.registrar(clientId: "c", payload: completo.merging(["visivel": "sim"]) { _, n in n }), "Contrato: visivel precisa ser booleano")
            assertTest(!b.registrar(clientId: "c", payload: completo.merging(["conexao": ["tipo": "4g", "x": 1] as [String: Any]]) { _, n in n }), "Contrato: conexao com chave desconhecida invalida")
            assertTest(!b.registrar(clientId: "c", payload: completo.merging(["conexao": "wifi"]) { _, n in n }), "Contrato: conexao que não é objeto invalida")
            assertTest(b.registrar(clientId: "c", payload: completo.merging(["droppedTotal": 1e15, "bufferS": 99999, "playbackRate": -3]) { _, n in n }),
                       "Contrato: valores gigantes são aceitos, mas limitados")
            let limitado = b.relatorio(clientId: "c")
            assertTest(limitado?.droppedTotal == 1_000_000_000_000 && limitado?.bufferS == 3600 && limitado?.playbackRate == 0, "Contrato: faixas dos campos novos")
            rel0 = rel0.addingTimeInterval(2)
            assertTest(b.registrar(clientId: "c", payload: ["rota": "MJPEG"]) && b.relatorio(clientId: "c")?.rttMs == nil, "Contrato: campos novos são opcionais (navegador antigo)")

            let ua = String(repeating: "A", count: 5_000)
            let amb = b.registrarAmbiente(clientId: "c", payload: ["userAgent": ua, "plataforma": "MacIntel", "telaLarg": 1440, "telaAlt": 900, "dpr": 2, "idioma": "pt-BR", "conexao": NSNull()])
            assertTest(amb?.userAgent?.count == 200 && amb?.telaLarg == 1440 && amb?.dpr == 2 && amb?.conexao == nil, "Contrato: ENV aceito, userAgent cortado em 200")
            assertTest(b.registrarAmbiente(clientId: "c", payload: ["userAgent": "outro"]) == nil, "Contrato: ENV só vale uma vez")
            assertTest(b.registrarAmbiente(clientId: "d", payload: ["userAgent": "ok\u{0007}bell"]) == nil, "Contrato: ENV com caractere de controle é recusado")
            assertTest(b.registrarAmbiente(clientId: "d", payload: ["userAgent": "ok", "segredo": "x"]) == nil, "Contrato: ENV com chave desconhecida é recusado")
            assertTest(b.registrarAmbiente(clientId: "d", payload: ["telaLarg": 9e99])?.telaLarg == 20_000, "Contrato: ENV com tela gigante é limitado")

            assertTest(StudentMetricsBook.validarEvento(["tipo": "hack", "dados": [String: Any]()]) == nil, "Contrato: tipo de evento fora da lista é recusado")
            assertTest(StudentMetricsBook.validarEvento(["tipo": "seek", "dados": ["a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7]]) == nil, "Contrato: EVENT com mais de 6 chaves é recusado")
            assertTest(StudentMetricsBook.validarEvento(["tipo": "seek", "dados": ["a": ["x": 1]]]) == nil, "Contrato: EVENT com valor aninhado é recusado")
            assertTest(StudentMetricsBook.validarEvento(["tipo": "seek", "dados": ["a": "x\n"]]) == nil, "Contrato: EVENT com texto não imprimível é recusado")
            assertTest(StudentMetricsBook.validarEvento(["tipo": "seek", "dados": ["a": Double.infinity]]) == nil, "Contrato: EVENT com número infinito é recusado")
            assertTest(StudentMetricsBook.validarEvento(["tipo": "seek", "dados": ["chave com espaço": 1]]) == nil, "Contrato: EVENT com chave estranha é recusado")
            let longo = StudentMetricsBook.validarEvento(["tipo": "rota", "dados": ["motivo": String(repeating: "m", count: 500), "n": 3] as [String: Any]])
            assertTest((longo?.dados["motivo"] as? String)?.count == 80 && longo?.dados["n"] as? Double == 3, "Contrato: texto do EVENT é cortado em 80")
            assertTest(StudentMetricsBook.validarEvento(nil) == nil && StudentMetricsBook.validarEvento(["tipo": 5]) == nil, "Contrato: EVENT malformado não derruba")

            var aceitos = 0
            for _ in 0..<12 where b.registrarEvento(clientId: "c", payload: ["tipo": "quota", "dados": ["n": 1]]) != nil { aceitos += 1 }
            assertTest(aceitos == StudentMetricsBook.maxEventosPorSegundo, "Contrato: no máximo \(StudentMetricsBook.maxEventosPorSegundo) EVENT por segundo (\(aceitos))")
            rel0 = rel0.addingTimeInterval(1.1)
            assertTest(b.registrarEvento(clientId: "c", payload: ["tipo": "quota", "dados": ["n": 1]]) != nil, "Contrato: depois de 1 s volta a aceitar EVENT")
            b.remover(clientId: "c")
            assertTest(b.ambiente(clientId: "c") == nil && b.relatorio(clientId: "c") == nil, "Contrato: desconectar apaga ambiente e medição")

            // Amostrador de CPU e memória do app.
            let amostrador = ProcessSampler()
            var conta = 0.0
            for i in 0..<2_000_000 { conta += Double(i).squareRoot() }
            let uso = amostrador.amostrar()
            assertTest(uso.cpuPct >= 0 && uso.memMB > 0 && conta > 0, "Amostrador: CPU >= 0 e memória > 0 (\(uso.cpuPct) %, \(uso.memMB) MB)")
            assertTest(!SessionEnvironment.modeloDoMac().isEmpty && ProcessInfo.processInfo.activeProcessorCount > 0, "Ambiente: modelo do Mac via sysctl")

            // Ponta a ponta com WebSocket real: entrada, saída com motivo, EVENT, chat sem texto.
            let pastaSessao = pasta.appendingPathComponent("servidor")
            let servidor = NetworkListenerService(port: 8180, webAssetsPath: FileManager.default.temporaryDirectory)
            servidor.diretorioDeMetricas = pastaSessao
            servidor.configurarSessaoDeMetricas(contexto: ["resolucao": "720p", "fonte": "monitor", "appsOcultos": 2], tempos: { ["Ana": ["aVistaPct": 80.0]] },
                                              configuracao: { ConfigDeCaptura(resolucao: "720p", fpsAlvo: 30, taxaAlvoBps: 2_000_000, fonte: "monitor") })
            try servidor.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            func abrirWS() async -> URLSessionWebSocketTask {
                var req = URLRequest(url: URL(string: "ws://127.0.0.1:8180/ws")!)
                req.setValue("TesteDeCabecalho/1.0", forHTTPHeaderField: "User-Agent")
                let s = URLSession.shared.webSocketTask(with: req)
                s.resume()
                _ = try? await s.receive()
                return s
            }
            let ana = await abrirWS(), bia = await abrirWS()
            try? await ana.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Ana\"}}"))
            try? await bia.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Bia\"}}"))
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? await ana.send(.string("{\"type\":\"ENV\",\"payload\":{\"userAgent\":\"Mozilla/5.0 Teste\",\"plataforma\":\"MacIntel\",\"telaLarg\":1440,\"telaAlt\":900,\"dpr\":2,\"idioma\":\"pt-BR\",\"conexao\":null}}"))
            try? await ana.send(.string("{\"type\":\"METRICS\",\"payload\":{\"rota\":\"H.264\",\"fps\":28,\"mbps\":2.1,\"dropped\":0,\"droppedTotal\":4,\"lagMs\":100,\"rttMs\":9,\"bufferS\":0.5,\"playbackRate\":1,\"visivel\":true,\"conexao\":null}}"))
            try? await ana.send(.string("{\"type\":\"EVENT\",\"payload\":{\"tipo\":\"seek\",\"dados\":{\"paraS\":12}}}"))
            try? await ana.send(.string("{\"type\":\"EVENT\",\"payload\":{\"tipo\":\"hack\",\"dados\":{}}}"))
            try? await ana.send(.string("{\"type\":\"CHAT_SEND\",\"payload\":{\"text\":\"SEGREDO-DO-CHAT-731\"}}"))
            try? await ana.send(.string("{\"type\":\"PRESENCE\",\"payload\":{\"visible\":false}}"))
            try? await Task.sleep(nanoseconds: 1_200_000_000) // passa a espera do ENV de Bia: entrada só com o cabeçalho
            servidor.registrarEventoDeSessao("pausa", ["origem": "professor"])
            servidor.registrarEventoDeSessao("chat", ["ligado": true, "alunosVeemUnsAosOutros": false])
            let taxaZero = StreamRates.entre(StreamSnapshot(), e: StreamSnapshot(), segundos: 2)!
            servidor.publicarMetricas(taxaZero, conexoes: [MedidaDeConexao(ip: "127.0.0.1", fps: 27, mbps: 1.5, quadros: 54, estouros: 1)], imprimir: false)
            bia.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
            ana.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let caminho = servidor.caminhoDoArquivoDeMetricas
            servidor.stop()
            let textoSessao = (try? String(contentsOf: caminho ?? pastaSessao, encoding: .utf8)) ?? ""
            let linhasSessao: [[String: Any]] = textoSessao.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            func tipoDe(_ t: String) -> [[String: Any]] { linhasSessao.filter { $0["tipo"] as? String == t } }
            assertTest(linhasSessao.first?["tipo"] as? String == "legenda" && linhasSessao.count == textoSessao.split(separator: "\n").count,
                       "Sessão real: legenda primeiro e todas as linhas são JSON")
            let ini = tipoDe("inicio").first
            assertTest(ini?["resolucao"] as? String == "720p" && ini?["appsOcultos"] as? Int == 2 && ini?["modeloMac"] is String
                       && (ini?["nucleos"] as? Int ?? 0) > 0 && ini?["limites"] != nil && ini?["porta"] as? Int == 8180,
                       "Sessão real: 'inicio' traz captura, Mac e limites")
            let entradaAna = tipoDe("entrada").first { $0["nome"] as? String == "Ana" }
            let entradaBia = tipoDe("entrada").first { $0["nome"] as? String == "Bia" }
            assertTest(entradaAna?["ip"] is String && entradaAna?["userAgent"] as? String == "Mozilla/5.0 Teste" && entradaAna?["plataforma"] as? String == "MacIntel"
                       && entradaAna?["telaLarg"] as? Int == 1440 && entradaAna?["idioma"] as? String == "pt-BR",
                       "Sessão real: 'entrada' com ip, userAgent e tela vindos do ENV")
            assertTest((entradaBia?["userAgent"] as? String)?.hasPrefix("TesteDeCabecalho") == true, "Sessão real: sem ENV, 'entrada' usa o User-Agent do cabeçalho")
            let saidaBia = tipoDe("saida").first { $0["nome"] as? String == "Bia" }
            assertTest(saidaBia?["motivo"] as? String == "fechou a aba" && saidaBia?["ip"] is String && (saidaBia?["duracaoS"] as? Int ?? -1) >= 0,
                       "Sessão real: 'saida' com motivo e duração")
            assertTest(tipoDe("seek").count == 1 && tipoDe("seek").first?["nome"] as? String == "Ana" && tipoDe("seek").first?["paraS"] as? Double == 12 && tipoDe("hack").isEmpty,
                       "Sessão real: EVENT válido vira linha com o nome; tipo inventado é descartado")
            assertTest(tipoDe("visibilidade").first?["visivel"] as? Bool == false, "Sessão real: linha de visibilidade")
            assertTest(tipoDe("pausa").first?["origem"] as? String == "professor" && tipoDe("chat").first?["ligado"] as? Bool == true, "Sessão real: pausa e chat (sem texto)")
            assertTest(tipoDe("amostra").contains { $0["pausada"] as? Bool == true && $0["cpuPct"] is Double }, "Sessão real: amostra marca a pausa e traz a CPU")
            let alunoAna = tipoDe("aluno").first { $0["nome"] as? String == "Ana" && $0["srvFps"] as? Double != nil }
            assertTest(alunoAna?["fps"] as? Double == 28 && alunoAna?["droppedTotal"] as? Int == 4 && alunoAna?["rttMs"] as? Int == 9
                       && alunoAna?["visivel"] as? Bool == true && alunoAna?["srvFps"] as? Double == 27 && alunoAna?["srvEstouros"] as? Int == 1,
                       "Sessão real: 'aluno' plano com medidas do navegador e do servidor (IP)")
            assertTest(alunoAna?["srvCompartilhado"] as? Bool == true, "Sessão real: dois alunos no mesmo IP marcam srvCompartilhado")
            assertTest(!textoSessao.contains("SEGREDO-DO-CHAT-731"), "Privacidade: o texto do chat nunca vai para o arquivo")
            assertTest(!textoSessao.contains("\"titulo\"") && !textoSessao.contains("\"janela\":\""), "Privacidade: nenhum título de janela no arquivo")
            let fimSessao = linhasSessao.last
            assertTest(tipoDe("amostra").contains { $0["resolucao"] as? String == "720p" && $0["blocoConfig"] as? Int == 1 }
                       && tipoDe("aluno").allSatisfy { $0["fonte"] as? String == "monitor" }, "Sessão real: o provedor de configuração chega em amostra e aluno")
            assertTest(fimSessao?["tipo"] as? String == "fim" && fimSessao?["picoAlunos"] as? Int == 2
                       && ((fimSessao?["alunos"] as? [[String: Any]])?.first { $0["nome"] as? String == "Ana" }?["aVistaPct"] as? Double) == 80,
                       "Sessão real: 'fim' com pico e resumo (tempos do ledger)")
        } catch {
            assertTest(false, "Falha nos testes de métricas ricas: \(error.localizedDescription)")
        }

}
