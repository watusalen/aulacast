import Foundation
import Network

/// Serviço responsável pela leitura e entrega segura de arquivos web estáticos (SRP & Segurança).
public final class StaticFileProviderService {
    private let webAssetsPath: URL
    
    public init(webAssetsPath: URL) {
        self.webAssetsPath = webAssetsPath
    }
    
    public func serve(connection: NWConnection, request: String) {
        let requestedPath = parsePath(from: request)
        var fileURL = webAssetsPath.appendingPathComponent(requestedPath).standardized

        // Se for requisição de favicon.ico e não existir no disco, retorna 204 No Content silenciosamente
        if requestedPath == "favicon.ico" && !FileManager.default.fileExists(atPath: fileURL.path) {
            send204(connection: connection)
            return
        }

        // O iOS/Safari sonda variantes de apple-touch-icon (precomposed, com tamanho no nome)
        // sem que a página as declare. Serve o ícone padrão para qualquer uma delas.
        if !FileManager.default.fileExists(atPath: fileURL.path), isAppleTouchIconProbe(requestedPath) {
            let defaultIcon = webAssetsPath.appendingPathComponent("apple-touch-icon.png").standardized
            if let iconData = try? Data(contentsOf: defaultIcon) {
                sendResponse(connection: connection, data: iconData, contentType: "image/png")
            } else {
                send204(connection: connection)
            }
            return
        }

        // Se for um diretório ou arquivo não encontrado, tenta index.html
        if !FileManager.default.fileExists(atPath: fileURL.path) && (requestedPath == "index.html" || requestedPath.isEmpty) {
            fileURL = webAssetsPath.appendingPathComponent("index.html").standardized
        }
        
        // Prevenção contra Directory Traversal (RNF-06).
        guard isInsideWebAssets(fileURL) else {
            print("[HTTP 404 Security Block] Path out of bounds: \(fileURL.path)")
            send404(connection: connection)
            return
        }
        
        guard let fileData = try? Data(contentsOf: fileURL) else {
            print("[HTTP 404 Not Found] File not found at: \(fileURL.path)")
            send404(connection: connection)
            return
        }
        
        let contentType = getContentType(for: fileURL.path)
        sendResponse(connection: connection, data: fileData, contentType: contentType)
    }
    
    /// Comparar caminhos com `hasPrefix` casa no meio de um nome de pasta: com a base
    /// `/x/web-assets`, o caminho `/x/web-assets-secreto/senhas.txt` passaria na verificação.
    /// A comparação correta é por componentes de caminho, que só casam em fronteira de pasta.
    private func isInsideWebAssets(_ fileURL: URL) -> Bool {
        let base = webAssetsPath.standardized.resolvingSymlinksInPath().pathComponents
        let alvo = fileURL.standardized.resolvingSymlinksInPath().pathComponents
        guard alvo.count >= base.count else { return false }
        return Array(alvo.prefix(base.count)) == base
    }

    /// Reconhece os nomes que o iOS tenta por conta própria: apple-touch-icon.png,
    /// apple-touch-icon-precomposed.png e as variantes com tamanho (ex.: -152x152).
    private func isAppleTouchIconProbe(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasPrefix("apple-touch-icon") && name.hasSuffix(".png")
    }

    private func parsePath(from request: String) -> String {
        guard let line = request.components(separatedBy: "\r\n").first else { return "index.html" }
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else { return "index.html" }
        
        var rawPath = parts[1]
        if let queryIndex = rawPath.firstIndex(of: "?") {
            rawPath = String(rawPath[..<queryIndex])
        }
        
        if rawPath == "/" || rawPath.isEmpty {
            return "index.html"
        }
        
        if rawPath.hasPrefix("/") {
            rawPath.removeFirst()
        }

        // O navegador envia o caminho percent-encoded: sem decodificar, qualquer nome com
        // espaço ou acento (comum em material de aula) nunca seria encontrado no disco.
        // A verificação de traversal roda depois desta etapa, sobre o caminho já decodificado.
        return rawPath.removingPercentEncoding ?? rawPath
    }
    
    private func getContentType(for filePath: String) -> String {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js":
            return "application/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "svg":
            return "image/svg+xml"
        case "ico":
            return "image/x-icon"
        case "ttf":
            return "font/ttf"
        case "webmanifest":
            return "application/manifest+json"
        default:
            return "application/octet-stream"
        }
    }
    
    private func sendResponse(connection: NWConnection, data: Data, contentType: String) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(data)
        
        connection.send(content: responseData, completion: .contentProcessed({ error in
            if let error = error {
                print("Erro ao enviar resposta HTTP: \(error)")
            }
            connection.cancel()
        }))
    }
    
    private func send204(connection: NWConnection) {
        let header = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func send404(connection: NWConnection) {
        let body = "<html><body><h1>404 Not Found</h1></body></html>"
        let header = "HTTP/1.1 404 Not Found\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(Data(body.utf8))
        
        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}