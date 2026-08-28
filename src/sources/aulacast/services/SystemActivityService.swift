import Foundation

/// Impede que o macOS estrangule o aplicativo durante a transmissão (DIP).
public protocol SystemActivityProtocol: AnyObject {
    func beginTransmission(reason: String)
    func endTransmission()
    var isHoldingActivity: Bool { get }
}

/// Mantém a transmissão viva quando o professor sai da janela do AulaCast.
///
/// Ao trocar de Mesa (Space) ou abrir outro aplicativo, o AulaCast deixa de estar visível e o
/// macOS passa a tratá-lo como ocioso: o **App Nap** agrupa temporizadores, reduz prioridade e
/// estrangula a rede. Como o envio dos quadros depende de temporizadores curtos, o resultado é
/// a transmissão travando justamente quando o professor vai demonstrar algo em outro app —
/// que é o problema clássico das soluções em Electron.
///
/// `beginActivity` declara ao sistema que há trabalho em andamento iniciado pelo usuário e que
/// a latência importa, o que desliga esse estrangulamento enquanto durar a aula.
public final class SystemActivityService: SystemActivityProtocol {
    private var token: NSObjectProtocol?

    public init() {}

    public var isHoldingActivity: Bool { token != nil }

    public func beginTransmission(reason: String) {
        guard token == nil else { return }

        token = ProcessInfo.processInfo.beginActivity(
            options: [
                // Trabalho iniciado pelo professor: não é ociosidade.
                .userInitiated,
                // Desliga o agrupamento de temporizadores, que é o que atrasa os quadros.
                .latencyCritical,
                // A tela não pode dormir no meio da aula: os alunos veriam a imagem congelar.
                .idleDisplaySleepDisabled,
                .idleSystemSleepDisabled
            ],
            reason: reason
        )
    }

    public func endTransmission() {
        guard let token = token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit {
        // Não deixa a permissão pendurada se o app for encerrado transmitindo.
        endTransmission()
    }
}
