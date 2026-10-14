import Foundation

/// Resolve a pasta web-assets em qualquer ambiente, sem depender da máquina de ninguém.
public struct WebAssetsPathResolver {
    public static func resolve() -> URL {
        let fileManager = FileManager.default
        let candidatos = candidatos(
            currentDir: URL(fileURLWithPath: fileManager.currentDirectoryPath),
            bundleURL: Bundle.main.bundleURL,
            resourceURL: Bundle.main.resourceURL
        )

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

    /// Onde procurar `web-assets`, em ordem de preferência.
    ///
    /// Rodando como `.app` empacotado, os arquivos de dentro do app vêm PRIMEIRO. Antes a
    /// pasta onde o app foi iniciado vencia: abrir o app de um terminal na pasta do projeto
    /// servia o `web-assets` daquela pasta (outra branch, outra versão) em vez do que o app
    /// carrega, e o servidor novo falava com um navegador antigo.
    public static func candidatos(currentDir: URL, bundleURL: URL, resourceURL: URL?) -> [URL] {
        let doBundle = resourceURL.map { [$0.appendingPathComponent("web-assets")] } ?? []
        let empacotado = bundleURL.pathExtension == "app"

        var candidatos: [URL] = empacotado ? doBundle : []
        // Executando de dentro de src/ (fluxo de desenvolvimento) ou da raiz do projeto.
        candidatos.append(currentDir.appendingPathComponent("web-assets"))
        candidatos.append(currentDir.appendingPathComponent("src/web-assets"))
        if !empacotado { candidatos += doBundle }

        // Vizinhanças do próprio executável: cobre o binário do SwiftPM em .build/,
        // subindo até achar a pasta do projeto.
        var diretorio = bundleURL
        for _ in 0..<6 {
            diretorio = diretorio.deletingLastPathComponent()
            guard diretorio.path != "/" else { break }
            candidatos.append(diretorio.appendingPathComponent("web-assets"))
            candidatos.append(diretorio.appendingPathComponent("src/web-assets"))
        }
        return candidatos
    }
}
