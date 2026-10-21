import Foundation

/// Grava a sessão em `~/AulaCast-metricas/sessao-AAAAMMDD-HHmmss.jsonl`: um objeto JSON por
/// linha, autoexplicativo para uma IA plotar. A 1ª linha é a `legenda` (dicionário de campos,
/// gráficos sugeridos e um prompt pronto); depois `inicio`, `amostra`/`aluno` a cada 2 s,
/// eventos e `fim`. Toda linha tem `tipo`, `tSeg` (segundos desde o início) e `t` (ISO 8601).
/// Só para depuração (`MetricasDebug`).
///
/// Nunca derruba nem trava o chamador: erro de disco é avisado uma vez e o arquivo é abandonado.
/// Limite de `limiteBytes` por arquivo (a legenda não conta); ao estourar, uma última linha `truncado`.
public final class MetricsFileLogger {
    public static let limitePadraoBytes = 64 * 1024 * 1024
    public static let versaoDoEsquema = 1
    static let maxAlunosNoResumo = 500

    public static var diretorioPadrao: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AulaCast-metricas", isDirectory: true)
    }

    public let limiteBytes: Int
    public private(set) var arquivo: URL?

    private let diretorio: URL
    private let agora: () -> Date
    private let lock = NSLock()
    private var handle: FileHandle?
    private var escritos = 0
    private var truncado = false
    private var avisouErro = false
    private var inicio: Date?
    private var picoAlunos = 0

    /// Acumulado por aluno (pelo nome) para o resumo do `fim`.
    private struct Acumulado {
        var amostras = 0
        var somaFps = 0.0, nFps = 0, minFps = Double.infinity
        var somaMbps = 0.0, nMbps = 0
        var droppedTotal = 0
    }
    private var porAluno: [String: Acumulado] = [:]

    /// Somas correntes de um bloco de configuração (resolução/fps/fonte constantes). O(1) por amostra.
    private struct Bloco {
        let config: ConfigDeCaptura
        let id: Int
        var duracao = 0.0, amostras = 0
        var somaAlunos = 0.0, somaMbpsTotal = 0.0, somaMbpsPorAluno = 0.0, nMbpsPorAluno = 0
        var somaFps = 0.0, somaMinFps = 0.0
        var somaLag = 0.0, nLag = 0
        var somaPerda = 0.0, nPerda = 0
        var somaCpu = 0.0, somaMem = 0.0
        var estourosBase = 0, pedidosBase = 0, estourosFim = 0, pedidosFim = 0
    }
    private var blocos: [Bloco] = []
    /// Número do bloco corrente: sobe a cada evento `config` (mesmo sem amostras no meio) e,
    /// por garantia, quando a configuração de uma amostra difere da anterior sem ter havido evento.
    private var contadorDeBloco = 1
    private var mudancaPendente = false
    private var ultimaAmostra: Date?

    public init(diretorio: URL = MetricsFileLogger.diretorioPadrao, limiteBytes: Int = MetricsFileLogger.limitePadraoBytes,
                agora: @escaping () -> Date = Date.init) {
        self.diretorio = diretorio
        self.limiteBytes = limiteBytes
        self.agora = agora
    }

    // MARK: - Ciclo de vida

    /// Abre o arquivo e escreve a `legenda` e o `inicio`. `contexto` entra no `inicio` (versão do
    /// app, Mac, rede, captura, limites...); `porta`, `resolucao` e `fps` valem se `contexto` não os trouxer.
    public func iniciar(porta: UInt16, resolucao: String? = nil, fps: Int? = nil, contexto: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        let t = agora()
        inicio = t
        do {
            try FileManager.default.createDirectory(at: diretorio, withIntermediateDirectories: true)
            let f = Self.formatador("yyyyMMdd-HHmmss").string(from: t)
            let url = diretorio.appendingPathComponent("sessao-\(f).jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: url)
            arquivo = url
        } catch {
            avisar(error)
            return
        }
        escrever(linha("legenda", Self.legenda(), em: t), contaNoLimite: false)
        var dados: [String: Any] = ["porta": Int(porta)]
        if let resolucao { dados["resolucao"] = resolucao }
        if let fps { dados["fps"] = fps }
        escrever(linha("inicio", dados.merging(contexto) { _, novo in novo }, em: t))
    }

    /// Escreve o `fim`. `tempos` (por nome do aluno) vem do `AttendanceLedger` e traz `naAulaS`,
    /// `aVistaS`, `aVistaPct`, `saidas` e `maiorTrechoS`; entra no resumo junto com o que as amostras acumularam.
    public func encerrar(tempos: [String: [String: Any]] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard let inicio else { return }
        let t = agora()
        var nomes = Set(porAluno.keys).union(tempos.keys)
        if nomes.count > Self.maxAlunosNoResumo { nomes = Set(nomes.sorted().prefix(Self.maxAlunosNoResumo)) }
        let resumo: [[String: Any]] = nomes.sorted().map { nome in
            var r: [String: Any] = ["nome": nome]
            if let a = porAluno[nome] {
                r["fpsMedio"] = a.nFps > 0 ? a.somaFps / Double(a.nFps) : NSNull()
                r["fpsMinimo"] = a.nFps > 0 ? a.minFps : NSNull()
                r["mbpsMedio"] = a.nMbps > 0 ? a.somaMbps / Double(a.nMbps) : NSNull()
                r["quadrosDescartados"] = a.droppedTotal
            }
            for (k, v) in tempos[nome] ?? [:] { r[k] = v }
            return r
        }
        escrever(linha("fim", ["duracaoS": Int(t.timeIntervalSince(inicio)), "picoAlunos": picoAlunos, "alunos": resumo,
                                  "porConfiguracao": resumoPorConfiguracao()], em: t),
                 ignorandoLimite: true)
        try? handle?.close()
        handle = nil
        self.inicio = nil
    }

    // MARK: - Linhas

    /// Linha de evento ou qualquer outro tipo, com `tipo`, `t` e `tSeg` acrescentados.
    public func registrar(tipo: String, dados: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        if tipo == "config" { contadorDeBloco += 1; mudancaPendente = true }
        escrever(linha(tipo, dados, em: agora()))
    }

    public func registrarEvento(_ tipo: String, nome: String) {
        registrar(tipo: tipo, dados: ["nome": nome])
    }

    /// Uma `amostra` do servidor seguida de uma linha `aluno` por aluno (`alunos`, já planas, ver `linhaDeAluno`).
    public func registrarAmostra(alunos: Int, h264: Int, mjpeg: Int, telaFps: Double, mediaFps: Double,
                                 minFps: Double, mbpsTotal: Double, estourosDeFila: Int,
                                 pedidosDeQuadroChave: Int, bytesTotais: Int = 0, cpuPct: Double = 0, memMB: Double = 0,
                                 pausada: Bool = false, aVista: Int? = nil, wifi: [String: Any]? = nil,
                                 config: ConfigDeCaptura = ConfigDeCaptura(), linhasDeAluno: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        let t = agora()
        picoAlunos = max(picoAlunos, alunos, linhasDeAluno.count)
        let vistos = aVista ?? linhasDeAluno.filter { $0["visivel"] as? Bool == true }.count
        let perda = Self.perdaEstimadaPct(telaFps: telaFps, mediaFps: mediaFps)
        let bloco = somarNoBloco(config: config, t: t, alunos: alunos, mbpsTotal: mbpsTotal, mediaFps: mediaFps, minFps: minFps,
                                 perda: perda, cpu: cpuPct, mem: memMB, estouros: estourosDeFila, pedidos: pedidosDeQuadroChave,
                                 lags: linhasDeAluno.compactMap { ($0["lagMs"] as? NSNumber)?.doubleValue })
        let campos: [String: Any] = [
            "blocoConfig": bloco, "resolucao": config.resolucao ?? NSNull(), "fpsAlvo": config.fpsAlvo ?? NSNull(),
            "taxaAlvoBps": config.taxaAlvoBps ?? NSNull(), "fonte": config.fonte ?? NSNull(), "fpsEncoder": config.fpsEncoder ?? NSNull()
        ]
        escrever(linha("amostra", campos.merging([
            "alunos": alunos, "aVista": vistos, "h264": h264, "mjpeg": mjpeg,
            "telaFps": telaFps, "mediaFps": mediaFps, "minFps": minFps, "mbpsTotal": mbpsTotal,
            "perdaEstimadaPct": perda.map { $0 as Any } ?? NSNull(),
            "estourosDeFila": estourosDeFila, "pedidosDeQuadroChave": pedidosDeQuadroChave,
            "bytesTotais": bytesTotais, "cpuPct": cpuPct, "memMB": memMB, "pausada": pausada,
            "wifi": wifi.map { $0 as Any } ?? NSNull()
        ] as [String: Any]) { a, _ in a }, em: t))
        for l in linhasDeAluno {
            acumular(l)
            escrever(linha("aluno", l.merging(campos) { a, _ in a }, em: t))
        }
    }

    /// Acumula a amostra no bloco da configuração atual (abre um novo se ela mudou) e devolve
    /// o `blocoConfig` (1, 2, ...). Os deltas de fila e quadro-chave contam desde o fim do bloco anterior.
    /// A duração do bloco soma o tempo desde a amostra anterior (no máximo 10 s); a 1ª amostra da sessão conta 0.
    private func somarNoBloco(config: ConfigDeCaptura, t: Date, alunos: Int, mbpsTotal: Double, mediaFps: Double, minFps: Double,
                              perda: Double?, cpu: Double, mem: Double, estouros: Int, pedidos: Int, lags: [Double]) -> Int {
        let mudou = blocos.last.map { !$0.config.mesmoBlocoQue(config) } ?? false
        if mudou && !mudancaPendente { contadorDeBloco += 1 }
        if blocos.isEmpty || mudou || mudancaPendente {
            mudancaPendente = false
            var novo = Bloco(config: config, id: contadorDeBloco)
            novo.estourosBase = blocos.last?.estourosFim ?? 0
            novo.pedidosBase = blocos.last?.pedidosFim ?? 0
            blocos.append(novo)
        }
        let dt = ultimaAmostra.map { min(max(0, t.timeIntervalSince($0)), 10) } ?? 0
        ultimaAmostra = t
        var b = blocos[blocos.count - 1]
        b.duracao += dt; b.amostras += 1
        b.somaAlunos += Double(alunos); b.somaMbpsTotal += mbpsTotal
        if alunos > 0 { b.somaMbpsPorAluno += mbpsTotal / Double(alunos); b.nMbpsPorAluno += 1 }
        b.somaFps += mediaFps; b.somaMinFps += minFps
        for l in lags { b.somaLag += l; b.nLag += 1 }
        if let perda { b.somaPerda += perda; b.nPerda += 1 }
        b.somaCpu += cpu; b.somaMem += mem
        b.estourosFim = estouros; b.pedidosFim = pedidos
        blocos[blocos.count - 1] = b
        return b.id
    }

    /// `fim.porConfiguracao`: uma entrada por bloco, `null` onde não houve medição.
    private func resumoPorConfiguracao() -> [[String: Any]] {
        blocos.map { b in
            func media(_ soma: Double, _ n: Int) -> Any { n > 0 ? soma / Double(n) : NSNull() }
            let r: [String: Any] = [
                "blocoConfig": b.id, "resolucao": b.config.resolucao ?? NSNull(), "fpsAlvo": b.config.fpsAlvo ?? NSNull(),
                "fpsEncoder": b.config.fpsEncoder ?? NSNull(), "taxaAlvoBps": b.config.taxaAlvoBps ?? NSNull(), "fonte": b.config.fonte ?? NSNull(),
                "duracaoS": b.duracao, "amostras": b.amostras,
                "alunosMedio": media(b.somaAlunos, b.amostras), "mbpsMedioTotal": media(b.somaMbpsTotal, b.amostras),
                "mbpsMedioPorAluno": media(b.somaMbpsPorAluno, b.nMbpsPorAluno), "fpsMedio": media(b.somaFps, b.amostras),
                "fpsMinimoMedio": media(b.somaMinFps, b.amostras), "lagMsMedio": media(b.somaLag, b.nLag),
                "perdaMediaPct": media(b.somaPerda, b.nPerda), "cpuMedioPct": media(b.somaCpu, b.amostras),
                "memMBMedio": media(b.somaMem, b.amostras),
                "estourosDeFila": b.estourosFim - b.estourosBase, "pedidosDeQuadroChave": b.pedidosFim - b.pedidosBase
            ]
            return r
        }
    }

    /// Uma linha `aluno` plana: o que o navegador reportou (`nil` se ainda não reportou) mais o
    /// que o servidor mediu para ele pelo IP (`srv*`, `null` sem conexão de vídeo). Função pura.
    public static func linhaDeAluno(nome: String, relatorio r: StudentMetricsReport?, reportadoHa: Double?,
                                    srv: MedidaDoServidor?) -> [String: Any] {
        func v(_ x: Any?) -> Any { x ?? NSNull() }
        return [
            "nome": nome, "rota": v(r?.rota), "fps": v(r?.fps), "mbps": v(r?.mbps), "dropped": v(r?.dropped),
            "droppedTotal": v(r?.droppedTotal), "lagMs": v(r?.lagMs), "rttMs": v(r?.rttMs), "bufferS": v(r?.bufferS),
            "playbackRate": v(r?.playbackRate), "visivel": v(r?.visivel), "reportadoHa": v(reportadoHa),
            "srvFps": v(srv?.fps), "srvMbps": v(srv?.mbps), "srvQuadros": v(srv?.quadros),
            "srvEstouros": v(srv?.estouros), "srvCompartilhado": v(srv?.compartilhado)
        ]
    }

    /// (1 - média/tela) * 100, entre 0 e 100; `nil` com a tela parada (não há o que perder).
    public static func perdaEstimadaPct(telaFps: Double, mediaFps: Double) -> Double? {
        guard telaFps > 0, telaFps.isFinite, mediaFps.isFinite else { return nil }
        return min(max((1 - mediaFps / telaFps) * 100, 0), 100)
    }

    // MARK: - Escrita (com o lock tomado)

    private func acumular(_ l: [String: Any]) {
        guard let nome = l["nome"] as? String else { return }
        if porAluno[nome] == nil, porAluno.count >= Self.maxAlunosNoResumo { return }
        var a = porAluno[nome] ?? Acumulado()
        a.amostras += 1
        if let fps = l["fps"] as? Double { a.somaFps += fps; a.nFps += 1; a.minFps = min(a.minFps, fps) }
        if let mbps = l["mbps"] as? Double { a.somaMbps += mbps; a.nMbps += 1 }
        if let d = l["droppedTotal"] as? Int { a.droppedTotal = max(a.droppedTotal, d) }
        porAluno[nome] = a
    }

    private func linha(_ tipo: String, _ dados: [String: Any], em t: Date) -> [String: Any] {
        var l = dados
        l["tipo"] = tipo
        l["t"] = iso(t)
        let seg = t.timeIntervalSince(inicio ?? t)
        l["tSeg"] = (seg * 1000).rounded() / 1000
        return l
    }

    private func escrever(_ objeto: [String: Any], ignorandoLimite: Bool = false, contaNoLimite: Bool = true) {
        guard let h = handle, !truncado || ignorandoLimite else { return }
        guard var dados = try? JSONSerialization.data(withJSONObject: objeto, options: [.withoutEscapingSlashes]) else { return }
        dados.append(0x0A)
        if !ignorandoLimite, contaNoLimite, escritos + dados.count > limiteBytes {
            truncado = true
            let t = agora()
            if let aviso = try? JSONSerialization.data(withJSONObject: linha("truncado", ["limiteBytes": limiteBytes], em: t)) {
                gravar(aviso + Data([0x0A]), em: h, contar: false)
            }
            return
        }
        gravar(dados, em: h, contar: contaNoLimite)
    }

    private func gravar(_ dados: Data, em h: FileHandle, contar: Bool) {
        do {
            try h.write(contentsOf: dados) // direto no descritor: cada linha já está no disco
            if contar { escritos += dados.count }
        } catch {
            avisar(error)
            try? h.close()
            handle = nil
        }
    }

    private func avisar(_ erro: Error) {
        guard !avisouErro else { return }
        avisouErro = true
        print("[Métricas] Não foi possível gravar o arquivo da sessão: \(erro.localizedDescription)")
    }

    private func iso(_ d: Date) -> String { Self.formatadorISO.string(from: d) }

    private static let formatadorISO = ISO8601DateFormatter()
    private static func formatador(_ formato: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = formato // fuso local
        return f
    }
}

/// Configuração da captura no instante da amostra; `nil` = desconhecido (nunca inventado).
public struct ConfigDeCaptura: Equatable {
    public var resolucao: String?
    public var fpsAlvo: Int?
    public var taxaAlvoBps: Int?
    public var fonte: String?
    /// fps com que a sessão do encoder foi criada (pode diferir de `fpsAlvo` logo após uma mudança).
    public var fpsEncoder: Int?

    public init(resolucao: String? = nil, fpsAlvo: Int? = nil, taxaAlvoBps: Int? = nil, fonte: String? = nil, fpsEncoder: Int? = nil) {
        self.resolucao = resolucao; self.fpsAlvo = fpsAlvo; self.taxaAlvoBps = taxaAlvoBps; self.fonte = fonte; self.fpsEncoder = fpsEncoder
    }

    /// Resolução, fps e fonte iguais (o que define um bloco); taxa e fps do encoder mudam sozinhos depois.
    func mesmoBlocoQue(_ o: ConfigDeCaptura) -> Bool {
        resolucao == o.resolucao && fpsAlvo == o.fpsAlvo && fonte == o.fonte
    }
}

/// Guarda a configuração atual para o servidor lê-la de outra thread sem tocar no view model.
public final class CaixaDeConfiguracao {
    private let lock = NSLock()
    private var valor = ConfigDeCaptura()
    public init() {}
    public func definir(_ novo: ConfigDeCaptura) { lock.lock(); valor = novo; lock.unlock() }
    public func ler() -> ConfigDeCaptura { lock.lock(); defer { lock.unlock() }; return valor }
}
