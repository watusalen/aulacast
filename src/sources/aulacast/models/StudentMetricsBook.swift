import Foundation

/// Conexão de rede que o navegador informa (`navigator.connection`; só existe no Chrome/Android).
public struct StudentConnectionInfo: Equatable {
    public let tipo: String?
    public let downlinkMbps: Double?
    public let rttMs: Int?

    public init(tipo: String? = nil, downlinkMbps: Double? = nil, rttMs: Int? = nil) {
        self.tipo = tipo; self.downlinkMbps = downlinkMbps; self.rttMs = rttMs
    }
}

/// O que um navegador mede do próprio vídeo (mensagem `METRICS`). Os números são `nil` na rota
/// MJPEG: o navegador não tem evento por quadro nela, então nada é inventado. Os campos além
/// dos cinco primeiros são opcionais (navegador antigo não os manda).
public struct StudentMetricsReport: Equatable {
    public let rota: String
    public let fps: Double?
    public let mbps: Double?
    public let dropped: Int?
    public let lagMs: Int?
    public var droppedTotal: Int?
    public var rttMs: Int?
    public var bufferS: Double?
    public var playbackRate: Double?
    public var visivel: Bool?
    public var conexao: StudentConnectionInfo?

    public init(rota: String, fps: Double?, mbps: Double?, dropped: Int?, lagMs: Int?,
                droppedTotal: Int? = nil, rttMs: Int? = nil, bufferS: Double? = nil,
                playbackRate: Double? = nil, visivel: Bool? = nil, conexao: StudentConnectionInfo? = nil) {
        self.rota = rota
        self.fps = fps
        self.mbps = mbps
        self.dropped = dropped
        self.lagMs = lagMs
        self.droppedTotal = droppedTotal
        self.rttMs = rttMs
        self.bufferS = bufferS
        self.playbackRate = playbackRate
        self.visivel = visivel
        self.conexao = conexao
    }
}

/// O que o navegador diz de si uma vez só (mensagem `ENV`).
public struct StudentEnvironment: Equatable {
    public let userAgent: String?
    public let plataforma: String?
    public let telaLarg: Int?
    public let telaAlt: Int?
    public let dpr: Double?
    public let idioma: String?
    public let conexao: StudentConnectionInfo?
}

/// Última medição de cada aluno, com validação estrita e limite de 1 mensagem por segundo.
/// Memória limitada: uma entrada por conexão, removida na desconexão. Seguro entre threads.
public final class StudentMetricsBook {
    public static let rotasValidas: Set<String> = ["H.264", "MJPEG"]
    public static let maxLinhas = 100
    static let chavesConhecidas: Set<String> = [
        "rota", "fps", "mbps", "dropped", "lagMs", "droppedTotal", "rttMs", "bufferS", "playbackRate", "visivel", "conexao"
    ]
    static let chavesDoAmbiente: Set<String> = ["userAgent", "plataforma", "telaLarg", "telaAlt", "dpr", "idioma", "conexao"]
    static let chavesDaConexao: Set<String> = ["tipo", "downlinkMbps", "rttMs"]
    static let intervaloMinimo: TimeInterval = 1

    /// Tipos de EVENT que o navegador pode mandar; qualquer outro é descartado.
    public static let eventosValidos: Set<String> = ["rota", "video_reconexao", "quota", "seek", "ws_reconexao"]
    public static let maxEventosPorSegundo = 5
    static let maxChavesDoEvento = 6
    static let maxTextoDoEvento = 80

    private let agora: () -> Date
    private let lock = NSLock()
    private var ultimas: [String: StudentMetricsReport] = [:]
    private var aceitoEm: [String: Date] = [:]
    private var ambientes: [String: StudentEnvironment] = [:]
    private var janelaDeEventos: [String: (inicio: Date, quantos: Int)] = [:]

    public init(agora: @escaping () -> Date = Date.init) {
        self.agora = agora
    }

    /// Valida `payload` e guarda. `false` se for inválido ou vier antes de 1 s da última aceita.
    @discardableResult
    public func registrar(clientId: String, payload: [String: Any]?) -> Bool {
        guard let relatorio = Self.validar(payload) else { return false }
        let t = agora()
        lock.lock()
        defer { lock.unlock() }
        if let anterior = aceitoEm[clientId], t.timeIntervalSince(anterior) < Self.intervaloMinimo { return false }
        aceitoEm[clientId] = t
        ultimas[clientId] = relatorio
        return true
    }

    /// Valida e guarda o `ENV`. Só a primeira mensagem vale (`nil` nas seguintes e nas inválidas).
    public func registrarAmbiente(clientId: String, payload: [String: Any]?) -> StudentEnvironment? {
        guard let amb = Self.validarAmbiente(payload) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard ambientes[clientId] == nil else { return nil }
        ambientes[clientId] = amb
        return amb
    }

    public func ambiente(clientId: String) -> StudentEnvironment? {
        lock.lock(); defer { lock.unlock() }
        return ambientes[clientId]
    }

    /// Valida um `EVENT` e aplica o limite de `maxEventosPorSegundo` por cliente. Devolve o
    /// tipo e os dados já saneados, ou `nil` (inválido, tipo fora da lista ou acima do limite).
    public func registrarEvento(clientId: String, payload: [String: Any]?) -> (tipo: String, dados: [String: Any])? {
        guard let evento = Self.validarEvento(payload) else { return nil }
        let t = agora()
        lock.lock()
        defer { lock.unlock() }
        var janela = janelaDeEventos[clientId] ?? (t, 0)
        if t.timeIntervalSince(janela.inicio) >= 1 { janela = (t, 0) }
        guard janela.quantos < Self.maxEventosPorSegundo else { return nil }
        janela.quantos += 1
        janelaDeEventos[clientId] = janela
        return evento
    }

    public func remover(clientId: String) {
        lock.lock()
        ultimas.removeValue(forKey: clientId)
        aceitoEm.removeValue(forKey: clientId)
        ambientes.removeValue(forKey: clientId)
        janelaDeEventos.removeValue(forKey: clientId)
        lock.unlock()
    }

    public func removerTudo() {
        lock.lock()
        ultimas.removeAll()
        aceitoEm.removeAll()
        ambientes.removeAll()
        janelaDeEventos.removeAll()
        lock.unlock()
    }

    public func relatorio(clientId: String) -> StudentMetricsReport? {
        lock.lock()
        defer { lock.unlock() }
        return ultimas[clientId]
    }

    /// Última medição de cada aluno com nome, e há quantos segundos chegou. Para o arquivo da sessão.
    public func relatorios(nomes: [String: String]) -> [String: (relatorio: StudentMetricsReport, reportadoHa: Double)] {
        lock.lock()
        let copia = ultimas
        let desde = aceitoEm
        lock.unlock()
        let agora = self.agora()
        return copia.reduce(into: [:]) { acc, par in
            guard nomes[par.key] != nil else { return }
            acc[par.key] = (par.value, agora.timeIntervalSince(desde[par.key] ?? agora))
        }
    }

    /// Linhas da tabela, ordenadas por nome e limitadas a `maxLinhas`. O(n log n) nos alunos.
    public func linhas(nomes: [String: String]) -> [[String: Any]] {
        lock.lock()
        let copia = ultimas
        let desde = aceitoEm
        lock.unlock()
        let agora = self.agora()
        let comNome: [(String, String, StudentMetricsReport)] = copia.compactMap { id, r in nomes[id].map { ($0, id, r) } }
        return comNome.sorted { $0.0 < $1.0 }.prefix(Self.maxLinhas).map { nome, id, r in
            [
                "nome": nome, "rota": r.rota,
                "fps": r.fps.map { $0 as Any } ?? NSNull(),
                "mbps": r.mbps.map { $0 as Any } ?? NSNull(),
                "dropped": r.dropped.map { $0 as Any } ?? NSNull(),
                "lagMs": r.lagMs.map { $0 as Any } ?? NSNull(),
                "reportadoHa": agora.timeIntervalSince(desde[id] ?? agora)
            ]
        }
    }

    // MARK: - Validação

    static func validar(_ payload: [String: Any]?) -> StudentMetricsReport? {
        guard let payload, payload.keys.allSatisfy(chavesConhecidas.contains),
              let rota = payload["rota"] as? String, rotasValidas.contains(rota),
              let fps = numero(payload["fps"], 0...240),
              let mbps = numero(payload["mbps"], 0...1000),
              let dropped = numero(payload["dropped"], 0...1e9),
              let lag = numero(payload["lagMs"], 0...3_600_000),
              let droppedTotal = numero(payload["droppedTotal"], 0...1e12),
              let rtt = numero(payload["rttMs"], 0...3_600_000),
              let buffer = numero(payload["bufferS"], 0...3600),
              let taxa = numero(payload["playbackRate"], 0...16),
              let visivel = booleano(payload["visivel"]),
              let conexao = conexao(payload["conexao"]) else { return nil }
        return StudentMetricsReport(
            rota: rota,
            fps: fps,
            mbps: mbps,
            dropped: dropped.map { Int($0) },
            lagMs: lag.map { Int($0) },
            droppedTotal: droppedTotal.map { Int($0) },
            rttMs: rtt.map { Int($0) },
            bufferS: buffer,
            playbackRate: taxa,
            visivel: visivel,
            conexao: conexao
        )
    }

    static func validarAmbiente(_ payload: [String: Any]?) -> StudentEnvironment? {
        guard let payload, payload.keys.allSatisfy(chavesDoAmbiente.contains),
              let ua = texto(payload["userAgent"], max: 200),
              let plataforma = texto(payload["plataforma"], max: 40),
              let larg = numero(payload["telaLarg"], 0...20_000),
              let alt = numero(payload["telaAlt"], 0...20_000),
              let dpr = numero(payload["dpr"], 0...16),
              let idioma = texto(payload["idioma"], max: 16),
              let conexao = conexao(payload["conexao"]) else { return nil }
        return StudentEnvironment(userAgent: ua, plataforma: plataforma, telaLarg: larg.map { Int($0) },
                                  telaAlt: alt.map { Int($0) }, dpr: dpr, idioma: idioma, conexao: conexao)
    }

    /// `{tipo, dados}`: tipo na lista fixa; `dados` plano com até `maxChavesDoEvento` chaves
    /// curtas, valores texto imprimível (cortado em 80), número finito ou booleano.
    public static func validarEvento(_ payload: [String: Any]?) -> (tipo: String, dados: [String: Any])? {
        guard let payload, payload.keys.allSatisfy({ $0 == "tipo" || $0 == "dados" }),
              let tipo = payload["tipo"] as? String, eventosValidos.contains(tipo) else { return nil }
        let bruto = payload["dados"]
        if bruto == nil || bruto is NSNull { return (tipo, [:]) }
        guard let dados = bruto as? [String: Any], dados.count <= maxChavesDoEvento else { return nil }
        var limpos: [String: Any] = [:]
        for (chave, valor) in dados {
            guard chave.count <= 24, !chave.isEmpty,
                  chave.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
            if let n = valor as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { limpos[chave] = n.boolValue; continue }
                guard n.doubleValue.isFinite else { return nil }
                limpos[chave] = n.doubleValue
            } else if let s = valor as? String {
                guard let t = texto(s, max: maxTextoDoEvento), let curto = t else { return nil }
                limpos[chave] = curto
            } else {
                return nil
            }
        }
        return (tipo, limpos)
    }

    /// Ausente ou `null` vale "sem medição" (`.some(nil)`); número ou texto numérico finito é
    /// limitado à faixa; qualquer outra coisa devolve `nil` e invalida a mensagem inteira.
    private static func numero(_ bruto: Any?, _ faixa: ClosedRange<Double>) -> Double?? {
        guard let bruto, !(bruto is NSNull) else { return .some(nil) }
        let n: Double
        if let s = bruto as? String {
            guard let d = Double(s) else { return nil }
            n = d
        } else if let num = bruto as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
            n = num.doubleValue
        } else {
            return nil
        }
        guard n.isFinite else { return nil }
        return .some(min(max(n, faixa.lowerBound), faixa.upperBound))
    }

    /// Ausente ou `null` vale `.some(nil)`; só booleano de verdade (0/1 e texto não valem).
    private static func booleano(_ bruto: Any?) -> Bool?? {
        guard let bruto, !(bruto is NSNull) else { return .some(nil) }
        guard let n = bruto as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return .some(n.boolValue)
    }

    /// Ausente ou `null` vale `.some(nil)`; texto sem caractere de controle, cortado em `max`.
    private static func texto(_ bruto: Any?, max: Int) -> String?? {
        guard let bruto, !(bruto is NSNull) else { return .some(nil) }
        guard let s = bruto as? String, !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control
            || $0.properties.generalCategory == .format || $0.properties.generalCategory == .lineSeparator
            || $0.properties.generalCategory == .paragraphSeparator }) else { return nil }
        return .some(String(s.prefix(max)))
    }

    /// `conexao`: `null`/ausente, ou objeto com só `tipo` (<= 16), `downlinkMbps` e `rttMs`.
    private static func conexao(_ bruto: Any?) -> StudentConnectionInfo?? {
        guard let bruto, !(bruto is NSNull) else { return .some(nil) }
        guard let d = bruto as? [String: Any], d.keys.allSatisfy(chavesDaConexao.contains),
              let tipo = texto(d["tipo"], max: 16),
              let down = numero(d["downlinkMbps"], 0...100_000),
              let rtt = numero(d["rttMs"], 0...3_600_000) else { return nil }
        return .some(StudentConnectionInfo(tipo: tipo, downlinkMbps: down, rttMs: rtt.map { Int($0) }))
    }
}
