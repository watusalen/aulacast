import Foundation

/// O que um navegador mede do próprio vídeo (mensagem `METRICS`). Os números são `nil` na rota
/// MJPEG: o navegador não tem evento por quadro nela, então nada é inventado.
public struct StudentMetricsReport: Equatable {
    public let rota: String
    public let fps: Double?
    public let mbps: Double?
    public let dropped: Int?
    public let lagMs: Int?

    public init(rota: String, fps: Double?, mbps: Double?, dropped: Int?, lagMs: Int?) {
        self.rota = rota
        self.fps = fps
        self.mbps = mbps
        self.dropped = dropped
        self.lagMs = lagMs
    }
}

/// Última medição de cada aluno, com validação estrita e limite de 1 mensagem por segundo.
/// Memória limitada: uma entrada por conexão, removida na desconexão. Seguro entre threads.
public final class StudentMetricsBook {
    public static let rotasValidas: Set<String> = ["H.264", "MJPEG"]
    public static let maxLinhas = 100
    static let chavesConhecidas: Set<String> = ["rota", "fps", "mbps", "dropped", "lagMs"]
    static let intervaloMinimo: TimeInterval = 1

    private let agora: () -> Date
    private let lock = NSLock()
    private var ultimas: [String: StudentMetricsReport] = [:]
    private var aceitoEm: [String: Date] = [:]

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

    public func remover(clientId: String) {
        lock.lock()
        ultimas.removeValue(forKey: clientId)
        aceitoEm.removeValue(forKey: clientId)
        lock.unlock()
    }

    public func removerTudo() {
        lock.lock()
        ultimas.removeAll()
        aceitoEm.removeAll()
        lock.unlock()
    }

    public func relatorio(clientId: String) -> StudentMetricsReport? {
        lock.lock()
        defer { lock.unlock() }
        return ultimas[clientId]
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
              let lag = numero(payload["lagMs"], 0...3_600_000) else { return nil }
        return StudentMetricsReport(
            rota: rota,
            fps: fps,
            mbps: mbps,
            dropped: dropped.map { Int($0) },
            lagMs: lag.map { Int($0) }
        )
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
}
