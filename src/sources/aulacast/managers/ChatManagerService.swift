import Foundation

/// Gerenciador com responsabilidade única de armazenar e processar mensagens do chat local (SRP).
public final class ChatManagerService: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    
    public init() {}
    
    public func addMessage(_ message: ChatMessage) {
        messages.append(message)
    }
    
    public func sendProfMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = ChatMessage(sender: "Professor", text: trimmed, isProf: true)
        addMessage(msg)
    }
}