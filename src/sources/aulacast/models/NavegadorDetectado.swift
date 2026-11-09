import Foundation

/// Palpite do navegador e do aparelho a partir do User-Agent (ADR-005). É só um palpite:
/// o texto vem do cliente e o iPad no modo desktop se anuncia como Mac. Desconhecido = nil.
public enum NavegadorDetectado {
    private static let navegadores: [(marcas: [String], nome: String)] = [
        (["Edg/", "EdgA/", "EdgiOS/"], "Edge"), (["OPR/", "Opera"], "Opera"),
        (["FxiOS", "Firefox"], "Firefox"), (["CriOS", "Chrome/"], "Chrome")
    ]
    private static let aparelhos: [(marca: String, nome: String)] = [
        ("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("CrOS", "Chromebook"),
        ("Windows", "Windows"), ("Macintosh", "Mac"), ("Linux", "Linux"), ("X11", "Linux")
    ]

    /// "<Navegador> no <Aparelho>"; só o navegador se o aparelho for desconhecido; nil sem navegador. O(1).
    public static func descrever(userAgent ua: String) -> String? {
        let achado = navegadores.first { $0.marcas.contains(where: ua.contains) }?.nome
            ?? (ua.contains("Safari/") && ua.contains("Version/") ? "Safari" : nil)
        guard let navegador = achado else { return nil }
        guard let aparelho = aparelhos.first(where: { ua.contains($0.marca) })?.nome else { return navegador }
        return "\(navegador) no \(aparelho)"
    }
}
