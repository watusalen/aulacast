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

    /// Quando o aluno levantou a mão, ou `nil` com a mão abaixada.
    ///
    /// Guardar o instante, e não só um sim/não, é o que permite pôr a lista na ordem de quem
    /// pediu primeiro, como no Meet. A mão vale só para esta conexão: se o aluno reconecta,
    /// a página dele manda de novo depois de se identificar.
    public var handRaisedAt: Date?

    public var isHandRaised: Bool { handRaisedAt != nil }

    public init(
        id: String = UUID().uuidString,
        name: String,
        ipAddress: String,
        connectedAt: Date = Date(),
        hasIdentified: Bool = false,
        isWatching: Bool = true,
        handRaisedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.connectedAt = connectedAt
        self.hasIdentified = hasIdentified
        self.isWatching = isWatching
        self.handRaisedAt = handRaisedAt
    }
}
