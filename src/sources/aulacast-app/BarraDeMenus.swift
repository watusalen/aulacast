import AppKit

/// Deixa na barra de menus só o menu do app e "Janela". O SwiftUI não tem como remover os
/// menus padrão (Arquivo, Editar, Visualizar, Ajuda), então o menu principal é enxugado aqui,
/// depois de montado. Sem o menu Editar, copiar e colar deixariam de funcionar nos campos de
/// texto: os atalhos são tratados por `instalarAtalhosDeEdicao()`.
final class DelegadoDoApp: NSObject, NSApplicationDelegate {
    private var monitorDeTeclas: Any?

    func applicationDidFinishLaunching(_ notificacao: Notification) {
        BarraDeMenus.enxugar()
        monitorDeTeclas = BarraDeMenus.instalarAtalhosDeEdicao()
        // O SwiftUI pode remontar o menu quando uma janela passa a ser a principal.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { _ in BarraDeMenus.enxugar() }
    }
}

enum BarraDeMenus {
    /// Remove tudo, menos o menu do app (o primeiro) e o menu de janelas ("Janela").
    static func enxugar() {
        DispatchQueue.main.async {
            guard let principal = NSApp.mainMenu else { return }
            for item in principal.items.dropFirst() where !ehMenuDeJanelas(item) {
                principal.removeItem(item)
            }
        }
    }

    private static func ehMenuDeJanelas(_ item: NSMenuItem) -> Bool {
        guard let submenu = item.submenu else { return false }
        if let janelas = NSApp.windowsMenu, submenu === janelas { return true }
        return submenu.title == "Janela" || submenu.title == "Window"
    }

    /// ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z e ⇧⌘Z, enviados a quem está com o foco, como o menu Editar faria.
    static func instalarAtalhosDeEdicao() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { evento in
            let modificadores = evento.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modificadores.contains(.command),
                  modificadores.isDisjoint(with: [.option, .control]),
                  let tecla = evento.charactersIgnoringModifiers?.lowercased() else { return evento }

            let comShift = modificadores.contains(.shift)
            let acao: Selector?
            switch (tecla, comShift) {
            case ("c", false): acao = #selector(NSText.copy(_:))
            case ("v", false): acao = #selector(NSText.paste(_:))
            case ("x", false): acao = #selector(NSText.cut(_:))
            case ("a", false): acao = #selector(NSText.selectAll(_:))
            case ("z", false): acao = Selector(("undo:"))
            case ("z", true): acao = Selector(("redo:"))
            default: acao = nil
            }
            guard let acao, NSApp.sendAction(acao, to: nil, from: nil) else { return evento }
            return nil
        }
    }
}
