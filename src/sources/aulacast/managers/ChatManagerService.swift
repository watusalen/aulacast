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

    /// A mensagem que o professor fixou para a turma (o link do Portal do Aluno, por
    /// exemplo), ou `nil`. Uma por vez: fixar outra substitui.
    ///
    /// Guardada como cópia, e não como índice no histórico: o histórico descarta as mais
    /// antigas, e a fixada precisa continuar de pé a aula inteira.
    @Published public private(set) var pinnedMessage: ChatMessage?

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

    /// Fixa uma mensagem do professor. Devolve se algo mudou, para quem chama saber se
    /// precisa avisar a turma.
    ///
    /// Só as do professor: fixar a pergunta de um aluno a mostraria para a turma inteira,
    /// e as mensagens dos alunos são privadas com o professor.
    @discardableResult
    public func pin(_ message: ChatMessage) -> Bool {
        guard message.isProf, pinnedMessage?.id != message.id else { return false }
        pinnedMessage = message
        return true
    }

    @discardableResult
    public func unpin() -> Bool {
        guard pinnedMessage != nil else { return false }
        pinnedMessage = nil
        return true
    }
}