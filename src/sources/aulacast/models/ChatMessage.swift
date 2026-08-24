import Foundation

/// Modelo de mensagem enviada no chat local offline da sala de aula.
public struct ChatMessage: Identifiable, Codable, Hashable {
    public let id: String
    public let sender: String
    public let text: String
    public let timestamp: Date
    public let isProf: Bool
    
    public init(id: String = UUID().uuidString, sender: String, text: String, timestamp: Date = Date(), isProf: Bool = false) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.isProf = isProf
    }
}