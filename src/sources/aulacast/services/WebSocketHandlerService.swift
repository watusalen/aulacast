import Foundation
import Network
import CryptoKit

/// Servico responsavel pela negociacao (Handshake RFC 6455) e transmissao bidirecional de mensagens WebSocket.
public final class WebSocketHandlerService {
    public weak var chatObserver: ChatObserverProtocol?
    public weak var clientObserver: ClientObserverProtocol?
    public weak var presenceObserver: StudentPresenceObserverProtocol?
    public var isChatEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return chatLiberado }
        set { lock.lock(); chatLiberado = newValue; lock.unlock() }
    }
    private var chatLiberado = true

    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    /// Um decodificador por conexão, cada um com seu buffer de bytes incompletos.
    private var decoders: [ObjectIdentifier: WebSocketFrameDecoder] = [:]
    /// Nome validado de cada aluno, pelo id da conexão.
    ///
    /// O remetente do chat sai daqui, e não do que o navegador
    /// manda em cada mensagem: antes um aluno podia escrever ao professor assinando como
    /// um colega (ou como "Professor") só trocando o campo `sender`.
    private var nomes: [String: String] = [:]
    /// Último estado da transmissão anunciado à turma, repetido no CONNECTED.
    ///
    /// Sem isto, quem reconectava (ou entrava no meio da aula) com a transmissão pausada
    /// ou encerrada via o último quadro congelado como se a aula estivesse ao vivo.
    private var estadoDaTransmissao: [String: String] = ["stream": "live"]
    private let lock = NSLock()

    /// Última vez que cada conexão mandou alguma coisa, e o aluno a que ela pertence.
    ///
    /// Um notebook que dorme ou sai do Wi-Fi não manda FIN: sem prazo, a conexão ficava
    /// aberta para sempre e o aluno virava um fantasma na lista, ao lado da entrada nova
    /// dele.
    private var ultimaAtividade: [ObjectIdentifier: Date] = [:]
    private var alunoDaConexao: [ObjectIdentifier: String] = [:]
    private var vigia: DispatchSourceTimer?

    /// O navegador manda PING a cada 10 s; três batidas perdidas são conexão morta.
    public static let tempoMaximoOcioso: TimeInterval = 30

    /// Teto de payload por frame. O cliente só envia JSON curto (chat, identificação);
    /// qualquer coisa maior é erro ou abuso e não deve virar alocação gigante.
    private static let maxPayloadBytes = 1 << 20 // 1 MB

    /// Limites do que aparece na tela do professor. O navegador já corta antes, mas um
    /// cliente adulterado mandava 900 KB de chat e o painel tentava desenhar tudo.
    public static let maxNameLength = 40
    public static let maxChatLength = 1000

    public init() {
        let vigia = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        vigia.schedule(deadline: .now() + 10, repeating: 10)
        vigia.setEventHandler { [weak self] in self?.derrubarOciosas() }
        vigia.resume()
        self.vigia = vigia
    }

    deinit {
        vigia?.cancel()
    }

    private func derrubarOciosas() {
        let limite = Date().addingTimeInterval(-Self.tempoMaximoOcioso)
        lock.lock()
        let mortas = ultimaAtividade.filter { $0.value < limite }.compactMap { item -> (ObjectIdentifier, NWConnection, String)? in
            guard let conexao = activeConnections[item.key], let aluno = alunoDaConexao[item.key] else { return nil }
            return (item.key, conexao, aluno)
        }
        lock.unlock()

        for (id, conexao, aluno) in mortas {
            print("[WebSocket] Conexão sem sinal há \(Int(Self.tempoMaximoOcioso)) s; encerrando.")
            removeConnection(id: id, clientId: aluno)
            conexao.cancel()
        }
    }

    /// Realiza o Handshake HTTP 101 Switching Protocols com a chave Sec-WebSocket-Key
    public func handleHandshake(connection: NWConnection, request: String) -> Bool {
        guard let clientKey = extractHeader("Sec-WebSocket-Key", from: request), !clientKey.isEmpty else {
            print("[WebSocket Warning] Cabecalho Sec-WebSocket-Key nao encontrado na requisicao.")
            // Responder e fechar: antes a conexão ficava aberta sem resposta nenhuma, e
            // qualquer um na rede podia empilhar sockets até esgotar os descritores do app.
            let recusa = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(recusa.utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
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
        ultimaAtividade[id] = Date()
        lock.unlock()

        // Extrai o IP do cliente
        var clientIp = "192.168.0.x"
        if case .hostPort(let host, _) = connection.endpoint {
            clientIp = "\(host)"
        }

        let connectedClient = ConnectedClient(name: "Aluno-\(String(clientIp.suffix(4)))", ipAddress: clientIp)
        lock.lock()
        alunoDaConexao[id] = connectedClient.id
        lock.unlock()
        clientObserver?.didClientConnect(connectedClient)

        // Envia mensagem de boas-vindas CONNECTED com o estado atual do chat. Sem isto, quem
        // entra (ou reconecta) no meio da aula com o chat já desligado veria o campo liberado
        // e só descobriria o bloqueio ao ver a mensagem sumir.
        lock.lock()
        var boasVindas: [String: Any] = estadoDaTransmissao
        boasVindas["chatEnabled"] = chatLiberado
        lock.unlock()
        let welcomeDict: [String: Any] = [
            "type": "CONNECTED",
            "payload": boasVindas
        ]
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

    /// Serializa uma mensagem de chat no formato esperado pelo cliente web.
    private func chatMessageJSON(_ message: ChatMessage) -> String? {
        let jsonDict: [String: Any] = [
            "type": "CHAT_MESSAGE",
            "payload": [
                "sender": message.sender,
                "text": message.text,
                "isProf": message.isProf
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: jsonDict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Transmite uma mensagem de chat para todos os clientes web conectados.
    /// Usado apenas para mensagens do professor — as dos alunos não circulam pela turma.
    public func broadcastChatMessage(_ message: ChatMessage) {
        guard let jsonString = chatMessageJSON(message) else { return }

        lock.lock()
        let connections = Array(activeConnections.values)
        lock.unlock()

        for conn in connections {
            sendTextFrame(connection: conn, text: jsonString)
        }
    }

    /// Devolve a mensagem apenas para quem a enviou, para que o aluno veja o próprio texto
    /// no histórico sem que ele chegue aos colegas.
    private func sendChatMessage(_ message: ChatMessage, to connection: NWConnection) {
        guard let jsonString = chatMessageJSON(message) else { return }
        sendTextFrame(connection: connection, text: jsonString)
    }

    /// Transmite uma mensagem de controle para todos os clientes web conectados.
    public func broadcastControlMessage(type: String, payload: [String: String]? = nil) {
        registrarEstado(type: type, payload: payload)

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

    private func registrarEstado(type: String, payload: [String: String]?) {
        let novo: [String: String]
        switch type {
        case "STREAM_STARTED", "STREAM_RESUMED": novo = ["stream": "live"]
        case "STREAM_PAUSED": novo = ["stream": "paused"]
        case "STREAM_ENDED": novo = ["stream": "ended", "reason": payload?["reason"] ?? ""]
        default: return
        }
        lock.lock()
        estadoDaTransmissao = novo
        lock.unlock()
    }

    /// Volta ao estado de uma sessão nova (servidor parado e religado).
    public func reset() {
        lock.lock()
        estadoDaTransmissao = ["stream": "live"]
        lock.unlock()
    }

    private func nomeIdentificado(_ clientId: String, senão fallbackName: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return nomes[clientId] ?? fallbackName
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

            // Bytes que chegam junto com o fim da conexão ainda são mensagens válidas.
            if error == nil, let data = data, !data.isEmpty {
                self.consumeFrames(
                    newBytes: data,
                    connection: connection,
                    clientId: clientId,
                    fallbackName: fallbackName,
                    connectionId: connectionId
                )
            }

            if isComplete || error != nil {
                // Cancelar é o que devolve o socket ao sistema. Só remover o registro deixava
                // a conexão em CLOSE_WAIT até o app fechar — uma por aluno que fechou a tampa
                // do notebook ou matou o navegador sem mandar CLOSE.
                self.removeConnection(id: connectionId, clientId: clientId)
                connection.cancel()
                return
            }

            // Se o frame recebido acabou de encerrar a conexão (CLOSE ou frame malformado),
            // não vale voltar a escutar: essa escuta falharia em seguida e o aluno seria
            // anunciado como desconectado uma segunda vez.
            guard self.isActive(connectionId) else { return }

            self.listenForFrames(
                connection: connection,
                clientId: clientId,
                fallbackName: fallbackName,
                connectionId: connectionId
            )
        }
    }

    private func isActive(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeConnections[id] != nil
    }

    /// Encerra o registro da conexão e avisa o professor — uma única vez.
    ///
    /// A mesma queda chega por dois caminhos (o frame de CLOSE e, logo depois, a falha da
    /// escuta): avisar em ambos tirava o aluno da lista duas vezes.
    private func removeConnection(id: ObjectIdentifier, clientId: String) {
        lock.lock()
        let estavaAtiva = activeConnections.removeValue(forKey: id) != nil
        // Sem isto, o buffer de recepção da conexão ficaria retido até o app fechar.
        decoders.removeValue(forKey: id)
        nomes.removeValue(forKey: clientId)
        ultimaAtividade.removeValue(forKey: id)
        alunoDaConexao.removeValue(forKey: id)
        lock.unlock()

        guard estavaAtiva else { return }
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
        if activeConnections[connectionId] != nil {
            ultimaAtividade[connectionId] = Date()
        }
        let decoder = decoders[connectionId] ?? {
            let novo = WebSocketFrameDecoder(maxPayloadBytes: Self.maxPayloadBytes, exigirMascara: true)
            decoders[connectionId] = novo
            return novo
        }()
        lock.unlock()

        let resultado = decoder.consume(newBytes)

        var encerrar = false
        var respostaDeClose: Data?

        switch resultado {
        case .protocolViolation:
            encerrar = true

        case .frames(let frames):
            for frame in frames {
                if frame.isClose {
                    encerrar = true
                    // Devolve o CLOSE (com o código recebido) antes de fechar, como pede a
                    // RFC 6455: sem isso o navegador registra uma queda anormal (1006).
                    respostaDeClose = WebSocketFrameEncoder.closeFrame(payload: frame.payload.prefix(2))
                    break
                }
                if frame.isPing {
                    // Ping de controle pede pong de controle com o mesmo payload (RFC 6455).
                    // Responder com um frame de texto fazia o navegador tratar a resposta
                    // como mensagem da aula, e o ping do proxy nunca era de fato respondido.
                    connection.send(
                        content: WebSocketFrameEncoder.pongFrame(payload: frame.payload),
                        completion: .contentProcessed({ _ in })
                    )
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
            if let respostaDeClose {
                connection.send(content: respostaDeClose, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else {
                connection.cancel()
            }
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
        case "CHAT_SEND":
            guard isChatEnabled else { return }
            let text = (payloadDict?["text"] as? String) ?? ""
            let sender = nomeIdentificado(clientId, senão: fallbackName)

            let trimmedText = String(
                text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxChatLength)
            )
            if !trimmedText.isEmpty {
                let chatMsg = ChatMessage(sender: sender, text: trimmedText, isProf: false)

                // A mensagem do aluno é privada com o professor: vai para o app do professor
                // e volta apenas para quem escreveu. Retransmiti-la à turma transformava o
                // chat em conversa paralela durante a aula.
                chatObserver?.didReceiveChatMessage(chatMsg)
                sendChatMessage(chatMsg, to: connection)
            }

        case "IDENTIFY":
            let nome = (payloadDict?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Revalida no servidor: confiar só na checagem do navegador deixaria a lista
            // da turma aceitar qualquer coisa vinda de um cliente adulterado.
            guard nome.count >= 2 else {
                let recusaJSON = "{\"type\":\"IDENTIFY_REJECTED\",\"payload\":{\"reason\":\"Informe seu nome para entrar na aula.\"}}"
                sendTextFrame(connection: connection, text: recusaJSON)
                return
            }
            guard nome.count <= Self.maxNameLength else {
                let recusaJSON = "{\"type\":\"IDENTIFY_REJECTED\",\"payload\":{\"reason\":\"Use um nome com até \(Self.maxNameLength) caracteres.\"}}"
                sendTextFrame(connection: connection, text: recusaJSON)
                return
            }

            lock.lock()
            nomes[clientId] = nome
            lock.unlock()

            presenceObserver?.didIdentifyStudent(clientId: clientId, name: nome)
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
        connection.send(
            content: WebSocketFrameEncoder.textFrame(text),
            completion: .contentProcessed({ _ in })
        )
    }

    private func calculateAcceptKey(for clientKey: String) -> String {
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }
}