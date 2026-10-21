import Foundation

/// Chamada em CSV (RF-21): uma linha por PESSOA identificada, para abrir no Excel/Planilhas.
/// Separador `;`, UTF-8 com BOM, linhas terminadas em CRLF, decimais com vírgula.
public enum ChamadaCSV {
    public static let cabecalho = ["Nome", "Presença", "Entrou", "Saiu", "Minutos na aula",
                                   "Minutos com a aula à vista", "Percentual à vista"]

    /// `resumos` vem do `AttendanceLedger.todos` (só quem tem nome). Ordem alfabética sem
    /// diferenciar caixa nem acento. `fimDaSessao` vale como saída de quem ainda está conectado.
    public static func gerar(resumos: [AttendanceSummary], fimDaSessao: Date, fuso: TimeZone = .current) -> Data {
        let data = DateFormatter()
        data.locale = Locale(identifier: "en_US_POSIX")
        data.timeZone = fuso
        data.dateFormat = "dd/MM/yyyy HH:mm"

        let ordenados = resumos.compactMap { r in r.nome.map { (chave: AttendanceLedger.normalizar($0), nome: $0, r: r) } }
            .sorted { ($0.chave, $0.r.entrouAs) < ($1.chave, $1.r.entrouAs) }

        var linhas = [cabecalho.joined(separator: ";")]
        for (_, nome, r) in ordenados {
            let saiu = r.conectada ? fimDaSessao : (r.ultimaSaidaAs ?? fimDaSessao)
            linhas.append([
                campo(nome), "Presente", data.string(from: r.entrouAs), data.string(from: saiu),
                decimal(r.naAula / 60), decimal(r.aVista / 60), decimal(r.fracaoAVista * 100)
            ].joined(separator: ";"))
        }
        return Data("\u{FEFF}".utf8) + Data((linhas.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Uma casa decimal, com vírgula, sem depender do idioma do sistema.
    static func decimal(_ valor: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), valor).replacingOccurrences(of: ".", with: ",")
    }

    /// Nome digitado pelo aluno: neutraliza fórmulas (`=`, `+`, `-`, `@`, tab, CR no começo viram
    /// texto com apóstrofo) e aplica aspas no estilo RFC 4180 se houver `;`, `"` ou quebra de linha.
    public static func campo(_ texto: String) -> String {
        var t = texto
        if let primeiro = t.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(primeiro) { t = "'" + t }
        guard t.contains(where: { $0 == ";" || $0 == "\"" || $0.isNewline }) else { return t }
        return "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// O que aconteceu ao tentar salvar a chamada ao fim da transmissão.
public enum ResultadoDaChamada: Equatable {
    case salva(arquivo: URL, alunos: Int)
    case vazia
    case falhou
}

/// Grava o CSV da chamada em `pasta/chamada-AAAA-MM-DD-HHmm.csv` (hora local), sem nunca
/// sobrescrever: se existir, tenta `-2`, `-3`... Erro de disco vira `.falhou`, nunca exceção.
public enum ChamadaWriter {
    public static func salvar(resumos: [AttendanceSummary], fimDaSessao: Date, pasta: URL = PastasDoApp.chamadas,
                              fuso: TimeZone = .current) -> ResultadoDaChamada {
        guard !resumos.isEmpty else { return .vazia }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = fuso
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let base = "chamada-\(f.string(from: fimDaSessao))"
        let dados = ChamadaCSV.gerar(resumos: resumos, fimDaSessao: fimDaSessao, fuso: fuso)
        do {
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            var n = 1
            while true {
                let url = pasta.appendingPathComponent(n == 1 ? "\(base).csv" : "\(base)-\(n).csv")
                do {
                    try dados.write(to: url, options: .withoutOverwriting)
                    return .salva(arquivo: url, alunos: resumos.count)
                } catch let erro as CocoaError where erro.code == .fileWriteFileExists {
                    n += 1
                    if n > 999 { return .falhou }
                }
            }
        } catch {
            return .falhou
        }
    }
}
