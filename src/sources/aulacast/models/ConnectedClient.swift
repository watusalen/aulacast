import Foundation

/// Modelo que representa um aluno/dispositivo conectado à transmissão local.
public struct ConnectedClient: Identifiable, Codable, Hashable {
    public let id: String
    public var name: String
    public var ipAddress: String
    public var connectedAt: Date

    /// A aba do aluno está visível na tela dele? Um aluno pode estar conectado e mesmo assim
    /// não estar vendo a aula — com a janela minimizada ou em outra aba.
    public var isWatching: Bool

    /// O aluno já disse o nome, ou ainda está com o rótulo automático da conexão?
    public var hasIdentified: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        ipAddress: String,
        connectedAt: Date = Date(),
        hasIdentified: Bool = false,
        isWatching: Bool = true
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.connectedAt = connectedAt
        self.hasIdentified = hasIdentified
        self.isWatching = isWatching
    }
}
