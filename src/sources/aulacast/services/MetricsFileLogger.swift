import Foundation

/// Grava a sessão em `~/AulaCast-metricas/sessao-AAAAMMDD-HHmmss.jsonl`: um objeto JSON por
/// linha (inicio, amostra, entrada, saida, fim). Só para depuração (`MetricasDebug`).
///
/// Nunca derruba nem trava o chamador: erro de disco é avisado uma vez e o arquivo é abandonado.
/// Limite de `limiteBytes` por arquivo; ao estourar, uma última linha `truncado`.
public final class MetricsFileLogger {
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

    public init(diretorio: URL = MetricsFileLogger.diretorioPadrao, limiteBytes: Int = 20 * 1024 * 1024,
                agora: @escaping () -> Date = Date.init) {
        self.diretorio = diretorio
        self.limiteBytes = limiteBytes
        self.agora = agora
    }

    // MARK: - Ciclo de vida

    public func iniciar(porta: UInt16, resolucao: String? = nil, fps: Int? = nil) {
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
        var l: [String: Any] = ["tipo": "inicio", "t": iso(t), "porta": Int(porta)]
        if let resolucao { l["resolucao"] = resolucao }
        if let fps { l["fps"] = fps }
        escrever(l)
    }

    public func encerrar() {
        lock.lock(); defer { lock.unlock() }
        guard let inicio else { return }
        let t = agora()
        escrever(["tipo": "fim", "t": iso(t), "duracaoS": Int(t.timeIntervalSince(inicio)), "picoAlunos": picoAlunos],
                 ignorandoLimite: true)
        try? handle?.close()
        handle = nil
        self.inicio = nil
    }

    // MARK: - Linhas

    public func registrarEvento(_ tipo: String, nome: String) {
        lock.lock(); defer { lock.unlock() }
        escrever(["tipo": tipo, "t": iso(agora()), "nome": nome])
    }

    public func registrarAmostra(alunos: Int, h264: Int, mjpeg: Int, telaFps: Double, mediaFps: Double,
                                 minFps: Double, mbpsTotal: Double, estourosDeFila: Int,
                                 pedidosDeQuadroChave: Int, detalhe: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        picoAlunos = max(picoAlunos, alunos, detalhe.count)
        escrever([
            "tipo": "amostra", "t": iso(agora()), "alunos": alunos, "h264": h264, "mjpeg": mjpeg,
            "telaFps": telaFps, "mediaFps": mediaFps, "minFps": minFps, "mbpsTotal": mbpsTotal,
            "perdaEstimadaPct": Self.perdaEstimadaPct(telaFps: telaFps, mediaFps: mediaFps).map { $0 as Any } ?? NSNull(),
            "estourosDeFila": estourosDeFila, "pedidosDeQuadroChave": pedidosDeQuadroChave,
            "alunosDetalhe": detalhe
        ])
    }

    /// (1 - média/tela) * 100, entre 0 e 100; `nil` com a tela parada (não há o que perder).
    public static func perdaEstimadaPct(telaFps: Double, mediaFps: Double) -> Double? {
        guard telaFps > 0, telaFps.isFinite, mediaFps.isFinite else { return nil }
        return min(max((1 - mediaFps / telaFps) * 100, 0), 100)
    }

    // MARK: - Escrita (com o lock tomado)

    private func escrever(_ objeto: [String: Any], ignorandoLimite: Bool = false) {
        guard let h = handle, !truncado || ignorandoLimite else { return }
        guard var dados = try? JSONSerialization.data(withJSONObject: objeto, options: [.withoutEscapingSlashes]) else { return }
        dados.append(0x0A)
        if !ignorandoLimite, escritos + dados.count > limiteBytes {
            truncado = true
            gravar(Data("{\"tipo\":\"truncado\"}\n".utf8), em: h)
            return
        }
        gravar(dados, em: h)
    }

    private func gravar(_ dados: Data, em h: FileHandle) {
        do {
            try h.write(contentsOf: dados) // direto no descritor: cada linha já está no disco
            escritos += dados.count
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
