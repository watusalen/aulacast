import Foundation

/// Gerenciador com responsabilidade única de armazenar e processar mensagens do chat local (SRP).
public final class ChatManagerService: ObservableObject {
    /// Teto do histórico em memória.
    ///
    /// O painel do professor recebe **todas** as mensagens de **todos** os alunos, e nada
    /// jamais era descartado: numa aula longa com turma cheia o histórico só crescia, junto
    /// com o custo de redesenhar a lista. Quinhentas mensagens cobrem qualquer aula de
    /// verdade; o que passa disso é rolagem que ninguém vai ler.
    public static let maxMessages = 500

    @Published public private(set) var messages: [ChatMessage] = []

    public init() {}

    public func addMessage(_ message: ChatMessage) {
        messages.append(message)

        // Descarta pelo começo: o que importa numa aula é o que acabou de ser dito.
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }
    
    public func sendProfMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = ChatMessage(sender: "Professor", text: trimmed, isProf: true)
        addMessage(msg)
    }
}