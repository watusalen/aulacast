import Foundation

/// Sinal de parada compartilhado entre o teste e uma fila de fundo. Os métodos são síncronos:
/// chamar `NSLock.lock()` direto de uma função assíncrona gera aviso no Swift 6, e aqui a trava
/// fica escondida atrás deles.
final class SinalDeParada: @unchecked Sendable {
    private let trava = NSLock()
    private var parado = false

    func parar() {
        trava.lock()
        parado = true
        trava.unlock()
    }

    var deveParar: Bool {
        trava.lock()
        defer { trava.unlock() }
        return parado
    }
}
