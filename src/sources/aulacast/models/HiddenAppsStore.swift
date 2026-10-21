import Foundation

/// App que o professor marcou para nunca aparecer na transmissão de tela inteira.
/// O nome fica guardado para listar o app mesmo quando ele não está em execução.
public struct HiddenApp: Codable, Hashable {
    public let bundleID: String
    public let nome: String

    public init(bundleID: String, nome: String) {
        self.bundleID = bundleID
        self.nome = nome
    }
}

/// Guarda, entre execuções, os apps ocultos da transmissão (por bundle ID, não por janela:
/// títulos de janela mudam o tempo todo e a lembrança falharia em silêncio).
public struct HiddenAppsStore {
    public static let chave = "aulacast.appsOcultos.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Dado ausente ou corrompido vira lista vazia: nunca derruba o app.
    public func carregar() -> [HiddenApp] {
        guard let dados = defaults.data(forKey: Self.chave),
              let apps = try? JSONDecoder().decode([HiddenApp].self, from: dados) else { return [] }
        return Self.ordenados(apps)
    }

    public func salvar(_ apps: [HiddenApp]) {
        guard let dados = try? JSONEncoder().encode(Self.ordenados(apps)) else { return }
        defaults.set(dados, forKey: Self.chave)
    }

    /// Ordem estável: por nome (sem diferenciar maiúsculas) e, no empate, por bundle ID.
    public static func ordenados(_ apps: [HiddenApp]) -> [HiddenApp] {
        apps.sorted {
            let ordem = $0.nome.caseInsensitiveCompare($1.nome)
            return ordem == .orderedSame ? $0.bundleID < $1.bundleID : ordem == .orderedAscending
        }
    }
}
