import Foundation

/// Arquivo que o professor disponibilizou para a turma baixar.
///
/// O aluno pede pelo `id` (um UUID sorteado), nunca por caminho: o servidor só entrega o
/// que está nesta lista, e não há como chegar a outro arquivo do Mac mexendo na URL.
public struct SharedFile: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let url: URL
    public let size: Int64
    public let sharedAt: Date

    public init(id: String = UUID().uuidString, name: String, url: URL, size: Int64, sharedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.size = size
        self.sharedAt = sharedAt
    }
}
