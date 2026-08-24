import Foundation

/// Modelo que representa um aluno/dispositivo conectado à transmissão local.
public struct ConnectedClient: Identifiable, Codable, Hashable {
    public let id: String
    public var name: String
    public var ipAddress: String
    public var connectedAt: Date
    public var isHandRaised: Bool

    /// Matrícula do IFPI informada pelo aluno ao entrar (vazia enquanto não se identificou).
    public var matricula: String

    /// A aba do aluno está visível na tela dele? Um aluno pode estar conectado e mesmo assim
    /// não estar vendo a aula — com a janela minimizada ou em outra aba.
    public var isWatching: Bool

    public var hasIdentified: Bool { !matricula.isEmpty }

    public init(
        id: String = UUID().uuidString,
        name: String,
        ipAddress: String,
        connectedAt: Date = Date(),
        isHandRaised: Bool = false,
        matricula: String = "",
        isWatching: Bool = true
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.connectedAt = connectedAt
        self.isHandRaised = isHandRaised
        self.matricula = matricula
        self.isWatching = isWatching
    }
}

/// Regras da matrícula do IFPI, no formato 202XXXXTADSXXXX (X = dígito).
/// Fica no núcleo, e não só no JavaScript, para que a validação valha também no servidor.
public enum MatriculaIFPI {
    /// 202 + 4 dígitos + TADS + 4 dígitos = 15 caracteres.
    public static let comprimento = 15

    public static func normalizar(_ bruta: String) -> String {
        bruta.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func ehValida(_ bruta: String) -> Bool {
        let texto = normalizar(bruta)
        guard texto.count == comprimento else { return false }

        let caracteres = Array(texto)
        guard texto.hasPrefix("202") else { return false }
        guard caracteres[7...10] == ["T", "A", "D", "S"] else { return false }

        let digitos = caracteres[3...6] + caracteres[11...14]
        return digitos.allSatisfy { $0.isNumber && $0.isASCII }
    }
}