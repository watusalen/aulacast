import Foundation

/// Resolve a pasta web-assets em qualquer ambiente, sem depender da máquina de ninguém.
public struct WebAssetsPathResolver {
    public static func resolve() -> URL {
        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        var candidatos: [URL] = [
            // 1. Executando de dentro de src/ (fluxo de desenvolvimento).
            currentDir.appendingPathComponent("web-assets"),
            // 2. Executando da raiz do projeto.
            currentDir.appendingPathComponent("src/web-assets")
        ]

        // 3. Recursos do app instalado (.app empacotado).
        if let bundleResources = Bundle.main.resourceURL {
            candidatos.append(bundleResources.appendingPathComponent("web-assets"))
        }

        // 4. Vizinhanças do próprio executável: cobre o binário do SwiftPM em .build/,
        //    subindo até achar a pasta do projeto. Substitui o caminho absoluto que antes
        //    estava fixo aqui e só funcionava no computador de quem escreveu o código.
        var diretorio = Bundle.main.bundleURL
        for _ in 0..<6 {
            diretorio = diretorio.deletingLastPathComponent()
            guard diretorio.path != "/" else { break }
            candidatos.append(diretorio.appendingPathComponent("web-assets"))
            candidatos.append(diretorio.appendingPathComponent("src/web-assets"))
        }

        for candidato in candidatos {
            var ehPasta: ObjCBool = false
            if fileManager.fileExists(atPath: candidato.path, isDirectory: &ehPasta), ehPasta.boolValue {
                return candidato.standardized
            }
        }

        // Sem nada encontrado, devolve o caminho mais provável para a mensagem de erro
        // apontar um lugar que faça sentido para quem for investigar.
        return candidatos[0]
    }
}
