import Foundation
import Network
import CryptoKit

/// Servico responsavel pela negociacao (Handshake RFC 6455) e transmissao bidirecional de mensagens WebSocket.
public final class WebSocketHandlerService {
    public weak var chatObserver: ChatObserverProtocol?
    public weak var handRaiseObserver: HandRaiseObserverProtocol?
    public weak var clientObserver: ClientObserverProtocol?
    public weak var presenceObserver: StudentPresenceObserverProtocol?
    public var isChatEnabled: Bool = true
    /// Vazio = professor não se identificou; o aluno vê o rótulo genérico da página.
    public var professorName: String = ""

    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    /// Um decodificador por conexão, cada um com seu buffer de bytes incompletos.
    private var decoders: [ObjectIdentifier: WebSocketFrameDecoder] = [:]
    private let lock = NSLock()

    /// Teto de payload por frame. O cliente só envia JSON curto (chat, mão levantada);
    /// qualquer coisa maior é erro ou abuso e não deve virar alocação gigante.
    private static let maxPayloadBytes = 1 << 20 // 1 MB

    public init() {}

    /// Realiza o Handshake HTTP 101 Switching Protocols com a chave Sec-WebSocket-Key
    public func handleHandshake(connection: NWConnection, request: String) -> Bool {
        guard let clientKey = extractHeader("Sec-WebSocket-Key", from: request) else {
            print("[WebSocket Warning] Cabecalho Sec-WebSocket-Key nao encontrado na requisicao.")
            return false
        }

        let acceptKey = calculateAcceptKey(for: clientKey)

        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

        connection.send(content: Data(response.utf8), completion: .contentProcessed({ error in
            if let error = error {
                print("[WebSocket Error] Falha ao enviar Handshake: \(error)")
            }
        }))

        // Registra a conexao ativa
        let id = ObjectIdentifier(connection)
        lock.lock()
        activeConnections[id] = connection
        lock.unlock()

        // Extrai o IP do cliente
        var clientIp = "192.168.0.x"
        if case .hostPort(let host, _) = connection.endpoint {
            clientIp = "\(host)"
        }

        let connectedClient = ConnectedClient(name: "Aluno-\(String(clientIp.suffix(4)))", ipAddress: clientIp, isHandRaised: false)
        clientObserver?.didClientConnect(connectedClient)

        // Envia mensagem de boas-vindas CONNECTED. O nome só vai junto se o professor
        // tiver se identificado; caso contrário a página do aluno mantém o rótulo genérico.
        var welcomeDict: [String: Any] = ["type": "CONNECTED"]
        let nomeExibido = professorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nomeExibido.isEmpty {
            welcomeDict["payload"] = ["profName": nomeExibido]
        }
        if let data = try? JSONSerialization.data(withJSONObject: welcomeDict),
           let welcomeJSON = String(data: data, encoding: .utf8) {
            sendTextFrame(connection: connection, text: welcomeJSON)
        }

        // Inicia escuta continua de frames WebSocket nessa conexao.
        // A identidade usada daqui pra frente é o id da conexão: o nome exibido pode mudar
        // quando o aluno digitar o dele, sem virar um registro novo na lista do professor.
        listenForFrames(
            connection: connection,
            clientId: connectedClient.id,
            fallbackName: connectedClient.name,
            connectionId: id
        )
        return true
    }

    /// Transmite uma mensagem de chat para todos os clientes web conectados
    public func broadcastChatMessage(_ message: ChatMessage) {
        let jsonDict: [String: Any] = [
            "type": "CHAT_MESSAGE",
            "payload": [
                "sender": message.sender,
                "text": message.text,
                "isProf": message.isProf
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: jsonDict),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        let connections = Array(activeConnections.values)
        lock.unlock()

        for conn in connections {
            sendTextFrame(connection: conn, text: jsonString)
        }
    }

    /// Transmite uma mensagem de controle para todos os clientes web conectados.
    public func broadcastControlMessage(type: String, payload: [String: String]? = nil) {
        var jsonDict: [String: Any] = ["type": type]
        if let payload = payload {
            jsonDict["payload"] = payload
        }

        guard let data = try? JSONSerialization.data(withJSONObject: jsonDict),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        let connections = Array(activeConnections.values)
        lock.unlock()

        for conn in connections {
            sendTextFrame(connection: conn, text: jsonString)
        }
    }

    /// Busca um cabecalho HTTP de forma estritamente case-insensitive
    private func extractHeader(_ headerName: String, from request: String) -> String? {
        let lines = request.components(separatedBy: "\r\n")
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 && parts[0].caseInsensitiveCompare(headerName) == .orderedSame {
                return parts[1]
            }
        }
        return nil
    }

    /// Escuta continua de frames WebSocket
    private func listenForFrames(
        connection: NWConnection,
        clientId: String,
        fallbackName: String,
        connectionId: ObjectIdentifier
    ) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if isComplete || error != nil {
                self.removeConnection(id: connectionId, clientId: clientId)
                return
            }

            if let data = data, !data.isEmpty {
                self.consumeFrames(
                    newBytes: data,
                    connection: connection,
                    clientId: clientId,
                    fallbackName: fallbackName,
                    connectionId: connectionId
                )
            }

            self.listenForFrames(
                connection: connection,
                clientId: clientId,
                fallbackName: fallbackName,
                connectionId: connectionId
            )
        }
    }

    private func removeConnection(id: ObjectIdentifier, clientId: String) {
        lock.lock()
        activeConnections.removeValue(forKey: id)
        // Sem isto, o buffer de recepção da conexão ficaria retido até o app fechar.
        decoders.removeValue(forKey: id)
        lock.unlock()
        clientObserver?.didClientDisconnect(clientId: clientId)
    }

    /// Acumula os bytes recebidos e consome todos os frames completos disponíveis.
    ///
    /// O TCP não respeita fronteira de mensagem: uma leitura pode trazer dois frames colados
    /// (um PING junto de uma mensagem de chat, por exemplo) ou apenas metade de um. Tratar
    /// cada leitura como se fosse exatamente um frame descartava mensagens em silêncio.
    private func consumeFrames(
        newBytes: Data,
        connection: NWConnection,
        clientId: String,
        fallbackName: String,
        connectionId: ObjectIdentifier
    ) {
        lock.lock()
        let decoder = decoders[connectionId] ?? {
            let novo = WebSocketFrameDecoder(maxPayloadBytes: Self.maxPayloadBytes)
            decoders[connectionId] = novo
            return novo
        }()
        lock.unlock()

        let resultado = decoder.consume(newBytes)

        var encerrar = false

        switch resultado {
        case .protocolViolation:
            encerrar = true

        case .frames(let frames):
            for frame in frames {
                if frame.isClose {
                    encerrar = true
                    break
                }
                if frame.isPing {
                    sendPong(connection: connection)
                } else if frame.isText, let jsonString = String(data: frame.payload, encoding: .utf8) {
                    processClientJSON(
                        jsonString,
                        clientId: clientId,
                        fallbackName: fallbackName,
                        connection: connection
                    )
                }
            }
        }

        if encerrar {
            removeConnection(id: connectionId, clientId: clientId)
            connection.cancel()
        }
    }

    /// Processa comandos recebidos em formato JSON do cliente web
    private func processClientJSON(
        _ jsonString: String,
        clientId: String,
        fallbackName: String,
        connection: NWConnection
    ) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        let payloadDict = json["payload"] as? [String: Any]

        switch type {
        case "RAISE_HAND":
            let active = (payloadDict?["active"] as? Bool) ?? true
            let informado = (payloadDict?["studentName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (informado?.isEmpty == false) ? informado! : fallbackName

            // Identifica pela conexão: trocar de nome atualiza o registro existente
            // em vez de criar um segundo aluno fantasma na lista do professor.
            handRaiseObserver?.didToggleHandRaise(clientId: clientId, displayName: name, isRaised: active)

            let ackJSON = "{\"type\":\"RAISE_HAND_ACK\",\"payload\":{\"active\":\(active)}}"
            sendTextFrame(connection: connection, text: ackJSON)

        case "CHAT_SEND":
            guard isChatEnabled else { return }
            let text = (payloadDict?["text"] as? String) ?? ""
            let sender = (payloadDict?["sender"] as? String) ?? fallbackName

            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                let chatMsg = ChatMessage(sender: sender, text: trimmedText, isProf: false)
                chatObserver?.didReceiveChatMessage(chatMsg)
                broadcastChatMessage(chatMsg)
            }

        case "IDENTIFY":
            let nome = (payloadDict?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let matricula = (payloadDict?["matricula"] as? String) ?? ""

            // Revalida no servidor: confiar só na checagem do navegador deixaria a lista
            // de presença aceitar qualquer coisa vinda de um cliente adulterado.
            guard !nome.isEmpty, MatriculaIFPI.ehValida(matricula) else {
                let recusaJSON = "{\"type\":\"IDENTIFY_REJECTED\",\"payload\":{\"reason\":\"Nome ou matrícula inválidos.\"}}"
                sendTextFrame(connection: connection, text: recusaJSON)
                return
            }

            presenceObserver?.didIdentifyStudent(
                clientId: clientId,
                name: nome,
                matricula: MatriculaIFPI.normalizar(matricula)
            )
            sendTextFrame(connection: connection, text: "{\"type\":\"IDENTIFY_ACCEPTED\"}")

        case "PRESENCE":
            let visivel = (payloadDict?["visible"] as? Bool) ?? true
            presenceObserver?.didChangeWatching(clientId: clientId, isWatching: visivel)

        case "PING":
            sendPong(connection: connection)

        default:
            break
        }
    }

    /// Envia resposta Pong
    private func sendPong(connection: NWConnection) {
        let pongJSON = "{\"type\":\"PONG\"}"
        sendTextFrame(connection: connection, text: pongJSON)
    }

    /// Envia mensagem de texto codificada em frame WebSocket (servidor -> cliente sem mascara)
    public func sendTextFrame(connection: NWConnection, text: String) {
        let payload = Data(text.utf8)
        var frame = Data()

        // FIN + Text frame (0x81)
        frame.append(0x81)

        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            return
        }

        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    private func calculateAcceptKey(for clientKey: String) -> String {
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }
}