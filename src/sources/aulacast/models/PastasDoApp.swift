import Foundation
import AppKit

/// Onde o app grava seus arquivos para o anfitrião. Um só lugar para trocar a raiz.
public enum PastasDoApp {
    /// `Documents/AulaCast` do usuário. Sem sandbox é `~/Documents/AulaCast`; com o App Sandbox
    /// (Mac App Store) o sistema devolve o Documents do contêiner do app
    /// (`~/Library/Containers/<id>/Data/Documents`), por isso nunca se monta o caminho à mão.
    public static var raiz: URL {
        let documentos = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documentos.appendingPathComponent("AulaCast", isDirectory: true)
    }
    /// Arquivo da sessão (`sessao-*.jsonl`), RF-20 / ADR-006.
    public static var metricas: URL { raiz.appendingPathComponent("Metricas", isDirectory: true) }
    /// Lista de presença em CSV ao encerrar a transmissão, RF-21.
    public static var chamadas: URL { raiz.appendingPathComponent("Listas de presença", isDirectory: true) }

    /// Abre a pasta de dados no Finder (cria se não existir). No sandbox o caminho do contêiner
    /// é escondido, então o anfitrião precisa deste atalho para achar métricas e listas de presença.
    @discardableResult
    public static func mostrarNoFinder() -> Bool {
        try? FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        return NSWorkspace.shared.open(raiz)
    }
}
