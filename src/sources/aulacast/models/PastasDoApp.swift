import Foundation

/// Onde o app grava seus arquivos para o professor. Um só lugar para trocar a raiz.
public enum PastasDoApp {
    /// `~/Documents/AulaCast`
    public static var raiz: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/AulaCast", isDirectory: true)
    }
    /// Arquivo da sessão (`sessao-*.jsonl`), RF-20 / ADR-006.
    public static var metricas: URL { raiz.appendingPathComponent("Metricas", isDirectory: true) }
    /// Chamada em CSV ao encerrar a transmissão, RF-21.
    public static var chamadas: URL { raiz.appendingPathComponent("Chamadas", isDirectory: true) }
}
