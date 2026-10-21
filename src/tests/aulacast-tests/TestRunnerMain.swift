import Foundation
import AppKit
import CoreMedia
import CoreVideo
import Network
import AulaCastCore

/// Descarta o CONNECTED e, em build de depuração, o DEBUG_INFO que vem logo depois.
func descartarBoasVindas(_ socket: URLSessionWebSocketTask) async {
    _ = try? await socket.receive()
    if MetricasDebug.consoleAtivo { _ = try? await socket.receive() }
}

@main
struct AulaCastTestRunner {
    @MainActor
    static func main() async {
        print("==========================================")
        print("  SUÍTE DE TESTES RIGOROSOS: AULACAST     ")
        print("==========================================")
        
        // Contadores em tipo de referência: com `var` local, o compilador conclui por engano
        // que o contador de falhas é sempre zero e marca o `exit(1)` final como inalcançável.
        final class Placar {
            var passou = 0
            var falhou = 0
            var puladas: [String] = []
        }
        // Modo padrão = CORE (só lógica pura, sem portas, sem codificador de hardware, sem esperas longas).
        // `--tudo` roda também as seções de rede real e H.264 (ver docs/04, seção 6).
        let executarTudo = CommandLine.arguments.contains("--tudo")

        // Auxiliares usados por seções core e não-core: ficam fora dos blocos `if executarTudo`.
        final class ColetorDeChat: ChatObserverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _recebidas: [ChatMessage] = []
            var recebidas: [ChatMessage] { trava.lock(); defer { trava.unlock() }; return _recebidas }
            func didReceiveChatMessage(_ message: ChatMessage) {
                trava.lock(); _recebidas.append(message); trava.unlock()
            }
        }

        func montarVM(permissao: Bool, capturaFalha: Bool = false) -> (MainViewModel, FakeCaptureService, FakeServer) {
            let captura = FakeCaptureService()
            captura.falhaAoIniciar = capturaFalha
            let servidor = FakeServer()
            let vm = MainViewModel(
                captureService: captura,
                encoderService: FakeEncoder(),
                serverService: servidor,
                advertiserService: FakeAdvertiser(),
                systemActivity: FakeSystemActivity(),
                permission: FakePermission(concedida: permissao),
                hostnameService: FakeHostname()
            )
            return (vm, captura, servidor)
        }
        let placar = Placar()

        func assertTest(_ condition: Bool, _ testName: String) {
            if condition {
                print("[PASS] \(testName)")
                placar.passou += 1
            } else {
                print("[FAIL] \(testName)")
                placar.falhou += 1
            }
        }

        // TESTE 1: ClientManagerService (RF-07 & UC-06: lista de alunos e identificação)
        print("\n--- [1/12] Testes de Domínio: ClientManagerService ---")
        let clientManager = ClientManagerService()

        clientManager.addOrUpdateClient(name: "Carlos - PC 04", ip: "192.168.1.50")
        assertTest(clientManager.clients.count == 1, "Conexão de novo aluno registra no gerenciador")
        assertTest(clientManager.clients.first?.name == "Carlos - PC 04", "Nome do aluno registrado corretamente")

        clientManager.addOrUpdateClient(name: "Mariana - PC 08", ip: "192.168.1.51")
        assertTest(clientManager.clients.count == 2, "Dois alunos registrados simultaneamente no gerenciador")

        // Trocar o nome exibido não pode criar um segundo registro para o mesmo aluno.
        if let client = clientManager.clients.first {
            let totalAntes = clientManager.clients.count
            clientManager.identify(clientId: client.id, name: "Carlos Eduardo")
            assertTest(clientManager.clients.count == totalAntes, "Aluno que se identifica depois não vira registro duplicado")
            assertTest(clientManager.clients.first?.name == "Carlos Eduardo", "Nome exibido é atualizado no registro existente")
        }

        // Um id desconhecido não deve inventar aluno na lista.
        let totalAntesDeIdInvalido = clientManager.clients.count
        clientManager.identify(clientId: "id-inexistente", name: "Fantasma")
        assertTest(clientManager.clients.count == totalAntesDeIdInvalido, "Identificação de conexão desconhecida é ignorada")

        // Caminho real ponta a ponta: o id criado no handshake precisa sobreviver até o
        // gerenciador, senão a identificação se perde em silêncio.
        let gerenciadorDeConexao = ClientManagerService()
        let alunoDoHandshake = ConnectedClient(name: "Aluno-1.99", ipAddress: "192.168.1.99")
        gerenciadorDeConexao.addOrUpdateClient(alunoDoHandshake)

        // Antes de dizer o nome, a conexão não aparece para o professor.
        assertTest(
            gerenciadorDeConexao.identifiedClients.isEmpty,
            "Conexão ainda sem nome não aparece na lista do professor"
        )
        gerenciadorDeConexao.identify(clientId: alunoDoHandshake.id, name: "Ana")

        assertTest(
            gerenciadorDeConexao.clients.first?.id == alunoDoHandshake.id,
            "Id gerado no handshake é preservado ao registrar o aluno"
        )
        assertTest(
            gerenciadorDeConexao.identifiedClients.first?.name == "Ana",
            "Com o nome dito, o aluno aparece na lista do professor"
        )

        if let client = clientManager.clients.first {
            clientManager.removeClient(id: client.id)
            assertTest(clientManager.clients.count == 1, "Desconexão de um aluno remove o cliente específico mantendo os demais")
        }

        // Histórico permanente de alunos (por IP): base do "X de Y baixaram" do painel de
        // Arquivos. Precisa sobreviver a quem desconecta, e não duplicar quem volta com o
        // mesmo IP.
        let turmaHistorico = ClientManagerService()
        turmaHistorico.addOrUpdateClient(name: "Beto", ip: "192.168.1.10")
        turmaHistorico.addOrUpdateClient(name: "Carla", ip: "192.168.1.11")
        turmaHistorico.addOrUpdateClient(name: "Dudu", ip: "192.168.1.12")
        assertTest(turmaHistorico.totalIdentificadosNaAula == 3, "Três alunos identificados entram no histórico permanente")

        if let saiu = turmaHistorico.clients.first(where: { $0.name == "Beto" }) {
            turmaHistorico.removeClient(id: saiu.id)
        }
        assertTest(
            turmaHistorico.totalIdentificadosNaAula == 3,
            "Desconectar não tira ninguém do histórico permanente (3 de 3 continua 3 de 3)"
        )
        assertTest(turmaHistorico.identifiedClients.count == 2, "Mas a lista de quem está na aula agora reflete a saída")

        // Reconectar com o mesmo IP (wifi caiu e voltou) não infla o histórico.
        turmaHistorico.addOrUpdateClient(name: "Beto", ip: "192.168.1.10")
        assertTest(
            turmaHistorico.totalIdentificadosNaAula == 3,
            "Reconexão com o mesmo IP não conta como um aluno novo no histórico"
        )

        turmaHistorico.reiniciarHistoricoDaAula()
        assertTest(turmaHistorico.totalIdentificadosNaAula == 0, "Reiniciar o histórico zera para a próxima aula")
        assertTest(turmaHistorico.clients.count == 3, "Reiniciar o histórico não mexe em quem está conectado agora")

        // Emenda real: WebSocket -> MainViewModel -> ClientManagerService.
        // Testar só o gerenciador não pega o defeito; ele morava na tradução entre camadas.
        let servidorFalso = FakeServer()
        let viewModel = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorFalso,
            advertiserService: FakeAdvertiser()
        )

        let alunoConectado = ConnectedClient(name: "Aluno-2.55", ipAddress: "192.168.2.55")
        viewModel.didClientConnect(alunoConectado)
        try? await Task.sleep(nanoseconds: 150_000_000)

        assertTest(
            viewModel.clientManager.clients.first?.id == alunoConectado.id,
            "Id do handshake sobrevive ao caminho completo até o gerenciador"
        )

        viewModel.didIdentifyStudent(clientId: alunoConectado.id, name: "Ana Beatriz")
        try? await Task.sleep(nanoseconds: 150_000_000)
        assertTest(
            viewModel.clientManager.identifiedClients.first?.name == "Ana Beatriz",
            "O nome chega ao app do professor pelo caminho completo"
        )
        assertTest(
            viewModel.clientManager.clients.count == 1,
            "Nome digitado não cria aluno duplicado no caminho completo"
        )

        // TESTE 2: ChatManagerService (UC-04 & RF-09: Chat Local Offline)
        print("\n--- [2/12] Testes de Domínio: ChatManagerService ---")
        let chatManager = ChatManagerService()
        
        let msg1 = ChatMessage(sender: "Mariana", text: "Dúvida no loop", isProf: false)
        chatManager.addMessage(msg1)
        assertTest(chatManager.messages.count == 1, "Mensagem do aluno adicionada ao histórico")
        assertTest(chatManager.messages.first?.sender == "Mariana", "Remetente da mensagem conferido")
        assertTest(chatManager.messages.first?.isProf == false, "Flag isProf == false para alunos")
        
        chatManager.sendProfMessage(text: "Use o comando for-in em Swift.")
        assertTest(chatManager.messages.count == 2, "Resposta do professor adicionada ao chat")
        assertTest(chatManager.messages.last?.isProf == true, "Flag isProf == true para mensagens do professor")
        
        let countBefore = chatManager.messages.count
        chatManager.sendProfMessage(text: "   \n\t  ")
        assertTest(chatManager.messages.count == countBefore, "Mensagens vazias ou só com espaços são descartadas")

        // TESTE 3: Segurança do Servidor Web (StaticFileProvider)
        print("\n--- [3/12] Testes de Segurança: StaticFileProviderService ---")
        let tempAssetsDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempAssetsDir, withIntermediateDirectories: true)
        
        let indexFile = tempAssetsDir.appendingPathComponent("index.html")
        try? "<html><body>Test</body></html>".write(to: indexFile, atomically: true, encoding: .utf8)
        
        // (A entrega de arquivos de verdade é testada abaixo, com requisições reais.)
        try? FileManager.default.removeItem(at: tempAssetsDir)

        if executarTudo {
        // TESTE 5: Servidor de Rede Local (NetworkListenerService)
        print("\n--- [4/12] Testes de Rede: NetworkListenerService ---")
        let serverService = NetworkListenerService(port: 8089, webAssetsPath: FileManager.default.temporaryDirectory)
        
        assertTest(serverService.port == 8089, "Porta do servidor atribuída corretamente")
        // O endereço sempre existe (há um reserva), então o que vale conferir é o formato.
        var enderecoBinario = in_addr()
        assertTest(
            inet_pton(AF_INET, serverService.localIPAddress, &enderecoBinario) == 1,
            "Endereço mostrado à turma é um IPv4 válido"
        )
        
        do {
            try serverService.start()
            assertTest(serverService.isRunning == true, "Servidor de rede iniciado com sucesso na porta 8089")
            // A flag sobe na hora; quem prova que a porta abriu é uma requisição de verdade.
            try? await Task.sleep(nanoseconds: 300_000_000)
            let resposta = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8089/nao-existe")!)
            assertTest(
                (resposta?.1 as? HTTPURLResponse) != nil,
                "Servidor responde de fato na porta 8089"
            )
            serverService.stop()
            assertTest(serverService.isRunning == false, "Servidor de rede encerrado de forma limpa")
        } catch {
            assertTest(false, "Falha ao iniciar servidor de teste: \(error.localizedDescription)")
        }

        // TESTE 5b: Directory traversal (RNF-06). A verificação antiga usava hasPrefix, que
        // casa no meio do nome da pasta: /x/web-assets-secreto passava como se fosse interno.
        print("\n--- [5/12] Testes de Segurança: Directory Traversal ---")
        let raizTemp = FileManager.default.temporaryDirectory.appendingPathComponent("aulacast_sec_\(UUID().uuidString)")
        let pastaPublica = raizTemp.appendingPathComponent("web-assets")
        let pastaIrma = raizTemp.appendingPathComponent("web-assets-secreto")
        try? FileManager.default.createDirectory(at: pastaPublica, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: pastaIrma, withIntermediateDirectories: true)
        try? "publico".write(to: pastaPublica.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try? "SEGREDO".write(to: pastaIrma.appendingPathComponent("senhas.txt"), atomically: true, encoding: .utf8)

        let servidorSeguranca = NetworkListenerService(port: 8099, webAssetsPath: pastaPublica)

        func corpoDaResposta(_ caminho: String) async -> (status: Int, corpo: String) {
            guard let url = URL(string: "http://127.0.0.1:8099/\(caminho)") else { return (-1, "") }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            guard let (dados, resposta) = try? await URLSession.shared.data(for: req),
                  let http = resposta as? HTTPURLResponse else { return (-1, "") }
            return (http.statusCode, String(data: dados, encoding: .utf8) ?? "")
        }

        do {
            try servidorSeguranca.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let legitimo = await corpoDaResposta("index.html")
            assertTest(legitimo.status == 200, "Arquivo legítimo continua sendo servido")

            // O ataque: escapar para a pasta irmã cujo nome começa igual.
            let ataqueIrma = await corpoDaResposta("../web-assets-secreto/senhas.txt")
            assertTest(
                !ataqueIrma.corpo.contains("SEGREDO"),
                "Pasta irmã com nome parecido não é acessível (traversal bloqueado)"
            )

            let ataqueAcima = await corpoDaResposta("../../etc/passwd")
            assertTest(ataqueAcima.status != 200, "Caminho acima da raiz continua bloqueado")

            servidorSeguranca.stop()
        } catch {
            assertTest(false, "Falha ao iniciar servidor de segurança: \(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: raizTemp)

        // TESTE 6: Sondagem de apple-touch-icon do iOS/Safari (evita 404 no log do professor)
        print("\n--- [6/12] Testes HTTP: fallback de apple-touch-icon ---")
        let iconAssetsDir = FileManager.default.temporaryDirectory.appendingPathComponent("aulacast_icon_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: iconAssetsDir, withIntermediateDirectories: true)

        // Só o nome canônico existe em disco; as variantes precisam cair no fallback.
        let iconBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try? iconBytes.write(to: iconAssetsDir.appendingPathComponent("apple-touch-icon.png"))

        let iconServer = NetworkListenerService(port: 8098, webAssetsPath: iconAssetsDir)

        func statusCode(forPath path: String) async -> Int {
            guard let url = URL(string: "http://127.0.0.1:8098/\(path)") else { return -1 }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return -1 }
            return http.statusCode
        }

        do {
            try iconServer.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let canonical = await statusCode(forPath: "apple-touch-icon.png")
            assertTest(canonical == 200, "apple-touch-icon.png é servido (recebido: \(canonical))")

            let precomposed = await statusCode(forPath: "apple-touch-icon-precomposed.png")
            assertTest(precomposed == 200, "apple-touch-icon-precomposed.png cai no fallback (recebido: \(precomposed))")

            let sized = await statusCode(forPath: "apple-touch-icon-152x152.png")
            assertTest(sized == 200, "variante com tamanho no nome cai no fallback (recebido: \(sized))")

            let missing = await statusCode(forPath: "arquivo-inexistente.png")
            assertTest(missing == 404, "arquivo realmente inexistente continua retornando 404 (recebido: \(missing))")

            iconServer.stop()
        } catch {
            assertTest(false, "Falha ao iniciar servidor de ícones: \(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: iconAssetsDir)

        } else { placar.puladas.append("T5-T6 rede/HTTP") }

        // TESTE 7: Frames WebSocket colados/partidos e comprimento absurdo.
        // O TCP não respeita fronteira de mensagem: tratar cada leitura como exatamente
        // um frame descartava mensagens de chat em silêncio.
        print("\n--- [7/12] Testes de Protocolo: frames WebSocket ---")

        func frameDeTexto(_ texto: String) -> Data {
            let payload = Array(texto.utf8)
            let mascara: [UInt8] = [0x1A, 0x2B, 0x3C, 0x4D]
            var frame = Data([0x81, UInt8(0x80 | payload.count)])
            frame.append(contentsOf: mascara)
            for (i, b) in payload.enumerated() {
                frame.append(b ^ mascara[i % 4])
            }
            return frame
        }

        func quantosFrames(_ resultado: WebSocketFrameDecoder.Result) -> Int {
            if case .frames(let lista) = resultado { return lista.count }
            return -1
        }

        // Dois frames numa única leitura (PING colado com uma mensagem de chat).
        let decodificador = WebSocketFrameDecoder()
        var colados = Data([0x89, 0x80, 0x00, 0x00, 0x00, 0x00]) // PING mascarado, sem payload
        colados.append(frameDeTexto("{\"type\":\"CHAT_SEND\"}"))
        let lidosColados = quantosFrames(decodificador.consume(colados))
        assertTest(lidosColados == 2, "Dois frames colados numa leitura são ambos processados (lidos: \(lidosColados))")

        // Frame partido ao meio entre duas leituras.
        let inteiro = frameDeTexto("{\"type\":\"PRESENCE\"}")
        let metade = inteiro.count / 2
        let decodificadorPartido = WebSocketFrameDecoder()
        let primeiraMetade = quantosFrames(decodificadorPartido.consume(inteiro.prefix(metade)))
        assertTest(primeiraMetade == 0, "Frame incompleto não é processado pela metade")
        let segundaMetade = quantosFrames(decodificadorPartido.consume(inteiro.suffix(from: metade)))
        assertTest(segundaMetade == 1, "Frame partido entre leituras é remontado e processado")

        // O conteúdo remontado precisa bater com o original, não só a contagem.
        let decodificadorConteudo = WebSocketFrameDecoder()
        _ = decodificadorConteudo.consume(inteiro.prefix(metade))
        if case .frames(let lista) = decodificadorConteudo.consume(inteiro.suffix(from: metade)),
           let frame = lista.first {
            assertTest(
                String(data: frame.payload, encoding: .utf8) == "{\"type\":\"PRESENCE\"}",
                "Payload remontado é idêntico ao enviado"
            )
        } else {
            assertTest(false, "Payload remontado é idêntico ao enviado")
        }

        // Do navegador para o servidor tudo vem mascarado; frames que a RFC proíbe derrubam.
        let semMascara = WebSocketFrameEncoder.textFrame("oi")
        assertTest(
            WebSocketFrameDecoder(exigirMascara: true).consume(semMascara) == .protocolViolation,
            "Servidor recusa frame sem máscara vindo do cliente"
        )
        var pingGigante = Data([0x89, 0x80 | 126, 0x00, 200, 0, 0, 0, 0])
        pingGigante.append(Data(repeating: 0, count: 200))
        assertTest(
            WebSocketFrameDecoder().consume(pingGigante) == .protocolViolation,
            "PING acima de 125 bytes é recusado (não vira PONG gigante)"
        )
        assertTest(
            WebSocketFrameDecoder().consume(Data([0x83, 0x80, 0, 0, 0, 0])) == .protocolViolation,
            "Opcode reservado é recusado"
        )
        assertTest(
            WebSocketFrameDecoder().consume(Data([0xC1, 0x80, 0, 0, 0, 0])) == .protocolViolation,
            "Bit RSV ligado sem extensão negociada é recusado"
        )
        assertTest(
            WebSocketFrameEncoder.closeFrame().first == 0x88,
            "Servidor sabe devolver CLOSE ao navegador"
        )

        // Roteamento pela linha de requisição, não por trecho solto do texto.
        assertTest(
            NetworkListenerService.linhaDeRequisicao("GET /stream?t=1 HTTP/1.1\r\nHost: x\r\n\r\n") == ("GET", "/stream"),
            "Caminho do vídeo é lido sem a query string"
        )
        assertTest(
            NetworkListenerService.linhaDeRequisicao("GET /stream-ajuda.html HTTP/1.1\r\n\r\n").caminho != "/stream",
            "Arquivo que começa com /stream não é confundido com o vídeo"
        )
        assertTest(
            !NetworkListenerService.pedeWebSocket("GET /?q=upgrade:%20websocket HTTP/1.1\r\nHost: x\r\n\r\n"),
            "'upgrade: websocket' fora dos cabeçalhos não vira handshake"
        )
        assertTest(
            NetworkListenerService.pedeWebSocket("GET /ws HTTP/1.1\r\nUpgrade: WebSocket\r\n\r\n"),
            "Cabeçalho Upgrade é reconhecido sem depender de maiúsculas"
        )

        // Comprimento de 8 bytes absurdo: precisa ser rejeitado, não virar alocação gigante.
        var absurdo = Data([0x81, 0xFF])
        absurdo.append(contentsOf: [UInt8](repeating: 0xFF, count: 8)) // comprimento gigantesco
        absurdo.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        let resultadoAbsurdo = WebSocketFrameDecoder().consume(absurdo)
        assertTest(
            resultadoAbsurdo == .protocolViolation,
            "Comprimento absurdo é rejeitado sem derrubar o app"
        )

        if executarTudo {
        // TESTE 8: WebSocket real ponta a ponta contra o servidor do app.
        // Cobre o handshake, a identificação e a presença pelo decodificador real.
        print("\n--- [8/12] Testes E2E: WebSocket real ---")

        final class ColetorDeEventos: ClientObserverProtocol, StudentPresenceObserverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _conectados: [ConnectedClient] = []
            private var _identificacoes: [(id: String, nome: String)] = []
            private var _presencas: [(id: String, assistindo: Bool)] = []

            var conectados: [ConnectedClient] { trava.lock(); defer { trava.unlock() }; return _conectados }
            var identificacoes: [(id: String, nome: String)] { trava.lock(); defer { trava.unlock() }; return _identificacoes }
            var presencas: [(id: String, assistindo: Bool)] { trava.lock(); defer { trava.unlock() }; return _presencas }

            func didClientConnect(_ client: ConnectedClient) {
                trava.lock(); _conectados.append(client); trava.unlock()
            }
            func didClientDisconnect(clientId: String) {}
            func didIdentifyStudent(clientId: String, name: String) {
                trava.lock(); _identificacoes.append((clientId, name)); trava.unlock()
            }
            func didChangeWatching(clientId: String, isWatching: Bool) {
                trava.lock(); _presencas.append((clientId, isWatching)); trava.unlock()
            }
        }

        let coletor = ColetorDeEventos()
        let servidorE2E = NetworkListenerService(port: 8100, webAssetsPath: FileManager.default.temporaryDirectory)
        servidorE2E.clientObserver = coletor
        servidorE2E.presenceObserver = coletor

        do {
            try servidorE2E.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8100/ws")!)
            socket.resume()

            // A mensagem de boas-vindas confirma que o handshake fechou.
            let boasVindas = try? await socket.receive()
            var handshakeOk = false
            if case .string(let texto)? = boasVindas, texto.contains("CONNECTED") {
                handshakeOk = true
            }
            assertTest(handshakeOk, "Handshake WebSocket completa e envia CONNECTED")

            // Mão levantada antes do IDENTIFY: não há nome validado para mostrar, então o
            // servidor ignora a mensagem, mas sem derrubar o aluno.
            try? await socket.send(.string("{\"type\":\"RAISE_HAND\",\"payload\":{\"active\":true}}"))
            try? await Task.sleep(nanoseconds: 400_000_000)

            assertTest(coletor.conectados.count == 1, "Servidor registrou o aluno na conexão")

            // O servidor pode ter mensagens já na fila, então é preciso ler até achar a
            // esperada em vez de assumir que vem primeiro.
            func aguardarMensagem(contendo trecho: String, tentativas: Int = 6) async -> Bool {
                for _ in 0..<tentativas {
                    guard case .string(let texto)? = try? await socket.receive() else { return false }
                    if texto.contains(trecho) { return true }
                }
                return false
            }

            // Identificação ponta a ponta pelo WebSocket real.
            try? await socket.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Ana Beatriz\"}}"))
            let identificacaoAceita = await aguardarMensagem(contendo: "IDENTIFY_ACCEPTED")
            try? await Task.sleep(nanoseconds: 300_000_000)

            assertTest(identificacaoAceita, "Servidor aceita a identificação do aluno pelo nome")
            assertTest(
                coletor.identificacoes.first?.id == coletor.conectados.first?.id,
                "Mão levantada antes de se identificar não derrubou a conexão: a identificação chega pelo mesmo aluno"
            )
            assertTest(coletor.identificacoes.count == 1, "Identificação chega ao app do professor")
            assertTest(coletor.identificacoes.first?.nome == "Ana Beatriz", "O nome informado chega ao professor")

            // Nome comprido demais também é recusado.
            let nomeLongo = String(repeating: "a", count: WebSocketHandlerService.maxNameLength + 1)
            try? await socket.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"\(nomeLongo)\"}}"))
            let recusouLongo = await aguardarMensagem(contendo: "IDENTIFY_REJECTED")
            assertTest(recusouLongo, "Servidor recusa nome acima do limite")

            // Nome vazio precisa ser recusado pelo servidor, e não só pelo navegador.
            try? await socket.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\" \"}}"))
            let recusou = await aguardarMensagem(contendo: "IDENTIFY_REJECTED")
            try? await Task.sleep(nanoseconds: 300_000_000)

            assertTest(recusou, "Servidor recusa nome vazio mesmo vindo de cliente adulterado")
            assertTest(coletor.identificacoes.count == 1, "Identificação inválida não entra na lista")

            // Presença: o aluno trocou de aba.
            try? await socket.send(.string("{\"type\":\"PRESENCE\",\"payload\":{\"visible\":false}}"))
            try? await Task.sleep(nanoseconds: 300_000_000)
            assertTest(coletor.presencas.last?.assistindo == false, "Aluno fora da tela é reportado ao professor")

            socket.cancel(with: .goingAway, reason: nil)

            // Quem entra na aula precisa receber o estado atual do chat já nas boas-vindas.
            // Sem isso, um aluno que chega atrasado (ou reconecta) com o chat desligado veria
            // o campo de mensagem liberado e só descobriria o bloqueio ao ver o texto sumir.
            var boasVindasChatLigado = ""
            let socketChatLigado = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8100/ws")!)
            socketChatLigado.resume()
            if case .string(let texto)? = try? await socketChatLigado.receive() {
                boasVindasChatLigado = texto
            }
            assertTest(boasVindasChatLigado.contains("CONNECTED"), "Aluno recebe boas-vindas ao conectar")
            assertTest(
                boasVindasChatLigado.contains("\"chatEnabled\":true"),
                "Chat ligado: as boas-vindas dizem que o aluno pode escrever"
            )
            assertTest(
                boasVindasChatLigado.contains("\"chatVisibleToClass\":false"),
                "Visibilidade para a turma desligada por padrão: as boas-vindas já dizem isso"
            )
            socketChatLigado.cancel(with: .goingAway, reason: nil)

            // Quem já está conectado precisa ver o aviso do chat mudar na hora quando o
            // professor liga a visibilidade no meio da aula — não só na próxima mensagem.
            let socketAoVivo = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8100/ws")!)
            socketAoVivo.resume()
            await descartarBoasVindas(socketAoVivo)

            servidorE2E.broadcastControlMessage(type: "CHAT_VISIBILITY", payload: ["visible": "true"])
            var avisoDeVisibilidade = ""
            if case .string(let texto)? = try? await socketAoVivo.receive() {
                avisoDeVisibilidade = texto
            }
            assertTest(
                avisoDeVisibilidade.contains("CHAT_VISIBILITY") && avisoDeVisibilidade.contains("\"visible\":\"true\""),
                "Ligar a visibilidade no meio da aula avisa quem já está conectado"
            )
            socketAoVivo.cancel(with: .goingAway, reason: nil)

            servidorE2E.isStudentChatVisibleToClass = true
            var boasVindasVisivel = ""
            let socketVisivel = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8100/ws")!)
            socketVisivel.resume()
            if case .string(let texto)? = try? await socketVisivel.receive() {
                boasVindasVisivel = texto
            }
            assertTest(
                boasVindasVisivel.contains("\"chatVisibleToClass\":true"),
                "Quem entra depois do professor ligar a visibilidade já chega sabendo"
            )
            socketVisivel.cancel(with: .goingAway, reason: nil)

            servidorE2E.isChatEnabled = false

            var boasVindasChatDesligado = ""
            let socketChatDesligado = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8100/ws")!)
            socketChatDesligado.resume()
            if case .string(let texto)? = try? await socketChatDesligado.receive() {
                boasVindasChatDesligado = texto
            }
            assertTest(
                boasVindasChatDesligado.contains("\"chatEnabled\":false"),
                "Chat desligado: quem entra depois já chega bloqueado"
            )

            socketChatDesligado.cancel(with: .goingAway, reason: nil)

            // Quem entra (ou reconecta) com a aula pausada ou encerrada precisa saber disso
            // já nas boas-vindas, e não ver o último quadro como se fosse ao vivo.
            func boasVindasDeNovoAluno() async -> String {
                let s = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8100/ws")!)
                s.resume()
                defer { s.cancel(with: .goingAway, reason: nil) }
                if case .string(let texto)? = try? await s.receive() { return texto }
                return ""
            }
            assertTest((await boasVindasDeNovoAluno()).contains("\"stream\":\"live\""), "Boas-vindas dizem que a aula está ao vivo")
            servidorE2E.broadcastControlMessage(type: "STREAM_PAUSED", payload: nil)
            assertTest((await boasVindasDeNovoAluno()).contains("\"stream\":\"paused\""), "Quem entra durante a pausa já sabe que está pausado")
            servidorE2E.broadcastControlMessage(type: "STREAM_ENDED", payload: ["reason": "Monitor desconectado"])
            let encerrada = await boasVindasDeNovoAluno()
            assertTest(
                encerrada.contains("\"stream\":\"ended\"") && encerrada.contains("Monitor desconectado"),
                "Quem entra depois da queda recebe o aviso e o motivo"
            )
            servidorE2E.broadcastControlMessage(type: "STREAM_STARTED", payload: nil)
            assertTest((await boasVindasDeNovoAluno()).contains("\"stream\":\"live\""), "A volta da aula volta a valer nas boas-vindas")

            servidorE2E.stop()
        } catch {
            assertTest(false, "Falha no teste E2E de WebSocket: \(error.localizedDescription)")
        }

        } else { placar.puladas.append("T8 WebSocket E2E") }

        // TESTE 10: Identificação do aluno e presença na tela.
        print("\n--- [9/12] Testes de Domínio: identificação e presença ---")

        let turma = ClientManagerService()
        let aluno = ConnectedClient(name: "Aluno-3.10", ipAddress: "192.168.3.10")
        turma.addOrUpdateClient(aluno)

        assertTest(turma.clients.first?.hasIdentified == false, "Aluno começa sem identificação")
        assertTest(turma.watchingCount == 0, "Conexão sem nome ainda não conta como aluno assistindo")

        turma.identify(clientId: aluno.id, name: "Ana Beatriz")
        assertTest(turma.watchingCount == 1, "Aluno identificado conta como assistindo")
        assertTest(turma.clients.first?.name == "Ana Beatriz", "Nome informado aparece na lista do professor")
        assertTest(turma.clients.first?.hasIdentified == true, "Aluno passa a constar como identificado")

        // O aluno minimizou a janela ou trocou de aba.
        turma.setWatching(clientId: aluno.id, isWatching: false)
        assertTest(turma.clients.first?.isWatching == false, "Aluno fora da tela é marcado como não assistindo")
        assertTest(turma.watchingCount == 0, "Contador de quem está vendo cai para zero")

        turma.setWatching(clientId: aluno.id, isWatching: true)
        assertTest(turma.watchingCount == 1, "Aluno que volta à tela volta a contar")

        // Identificação vinda de conexão desconhecida não pode criar aluno.
        let totalAntesDeIdentificacaoInvalida = turma.clients.count
        turma.identify(clientId: "id-inexistente", name: "Fantasma")
        turma.setWatching(clientId: "id-inexistente", isWatching: false)
        assertTest(
            turma.clients.count == totalAntesDeIdentificacaoInvalida,
            "Identificação de conexão desconhecida é ignorada"
        )

        if executarTudo {
        // TESTE 10: Prévia local do professor.
        // Ela mostra o último quadro realmente transmitido; se parar de atualizar, o professor
        // perde a única confirmação visual de que os alunos estão vendo alguma coisa.
        print("\n--- [10/12] Testes de Domínio: prévia da transmissão ---")

        let servidorDaPrevia = FakeServer()
        let vmPrevia = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorDaPrevia,
            advertiserService: FakeAdvertiser()
        )

        // JPEG real, para o NSImage conseguir decodificar de verdade.
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        let jpegDeTeste = bitmap?.representation(using: .jpeg, properties: [:]) ?? Data()
        assertTest(!jpegDeTeste.isEmpty, "JPEG de teste foi gerado")

        assertTest(vmPrevia.latestPreviewImage == nil, "Prévia começa vazia")

        vmPrevia.didReceiveEncodedFrame(data: jpegDeTeste, isKeyFrame: true)
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(vmPrevia.latestPreviewImage != nil, "Quadro transmitido atualiza a prévia do professor")

        // Pausado, a prévia não deve avançar — mas também não pode sumir. A espera passa
        // do limite de 2 fps da prévia: sem isso o teste passava até sem a pausa.
        try? await Task.sleep(nanoseconds: 600_000_000)
        vmPrevia.togglePause()
        let previaAntesDaPausa = vmPrevia.latestPreviewImage
        let quadrosAntesDaPausa = servidorDaPrevia.quadrosEnviados
        vmPrevia.didReceiveEncodedFrame(data: jpegDeTeste, isKeyFrame: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTest(
            servidorDaPrevia.quadrosEnviados == quadrosAntesDaPausa,
            "Em pausa, nenhum quadro novo chega aos alunos"
        )
        assertTest(
            vmPrevia.latestPreviewImage === previaAntesDaPausa,
            "Em pausa, a prévia congela no último quadro em vez de sumir"
        )
        vmPrevia.togglePause()

        // Encerrar limpa a prévia, para não deixar imagem antiga na tela.
        vmPrevia.stopStream()
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTest(vmPrevia.latestPreviewImage == nil, "Encerrar a transmissão limpa a prévia")

        // TESTE 11: Privacidade do chat com dois alunos conectados de verdade.
        // Mensagem de aluno é conversa reservada com o professor; só as do professor
        // circulam pela turma.
        print("\n--- [11/12] Testes E2E: privacidade do chat ---")


        let coletorChat = ColetorDeChat()
        let servidorChat = NetworkListenerService(port: 8101, webAssetsPath: FileManager.default.temporaryDirectory)
        servidorChat.chatObserver = coletorChat

        do {
            try servidorChat.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let alunoA = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8101/ws")!)
            let alunoB = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8101/ws")!)
            alunoA.resume()
            alunoB.resume()

            await descartarBoasVindas(alunoA)
            await descartarBoasVindas(alunoB)

            /// Guarda a primeira mensagem que chegar numa conexão.
            /// Só um `receive` fica pendente por socket: encadear vários deixa o anterior na
            /// fila e a chamada seguinte espera para sempre (foi o que travou esta suíte).
            final class CaixaDeEscuta: @unchecked Sendable {
                private let trava = NSLock()
                private var _texto: String?
                var texto: String? { trava.lock(); defer { trava.unlock() }; return _texto }
                func guardar(_ t: String) { trava.lock(); if _texto == nil { _texto = t }; trava.unlock() }
            }

            // O colega fica escutando desde antes da mensagem do aluno A.
            let escutaDoColega = CaixaDeEscuta()
            Task {
                if case .string(let texto)? = try? await alunoB.receive() {
                    escutaDoColega.guardar(texto)
                }
            }

            // Aluno A escreve para o professor.
            try? await alunoA.send(.string("{\"type\":\"CHAT_SEND\",\"payload\":{\"sender\":\"Ana\",\"text\":\"Nao estou enxergando\"}}"))
            try? await Task.sleep(nanoseconds: 400_000_000)

            assertTest(coletorChat.recebidas.count == 1, "Mensagem do aluno chega ao professor")
            assertTest(coletorChat.recebidas.first?.text == "Nao estou enxergando", "Texto preservado no app do professor")

            // O próprio autor recebe de volta, para ver o que escreveu.
            var ecoParaAutor = false
            if case .string(let texto)? = try? await alunoA.receive(), texto.contains("Nao estou enxergando") {
                ecoParaAutor = true
            }
            assertTest(ecoParaAutor, "O autor recebe a própria mensagem de volta")

            // Tempo de rede real antes de concluir que nada chegou ao colega.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            assertTest(
                escutaDoColega.texto == nil,
                "Mensagem de aluno NÃO chega aos colegas (recebido: \(escutaDoColega.texto ?? "nada"))"
            )

            // Já a mensagem do professor vai para todo mundo — inclusive para o colega,
            // cuja escuta continua pendente e agora deve ser satisfeita.
            servidorChat.broadcastChatMessage(
                ChatMessage(sender: "Ana Souza", text: "Vou aumentar a fonte", isProf: true)
            )

            var professorChegouEmA = false
            if case .string(let t)? = try? await alunoA.receive(), t.contains("Vou aumentar a fonte") {
                professorChegouEmA = true
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            let professorChegouEmB = escutaDoColega.texto?.contains("Vou aumentar a fonte") ?? false

            assertTest(professorChegouEmA, "Mensagem do professor chega a quem escreveu")
            assertTest(professorChegouEmB, "Mensagem do professor chega também ao colega")

            // Desligar o chat não pode ser só um aviso na tela: um cliente adulterado que
            // ignore o bloqueio e mande a mensagem assim mesmo continua sem alcançar o professor.
            servidorChat.isChatEnabled = false
            let recebidasAntes = coletorChat.recebidas.count

            try? await alunoA.send(.string("{\"type\":\"CHAT_SEND\",\"payload\":{\"sender\":\"Ana\",\"text\":\"passa mesmo assim\"}}"))
            try? await Task.sleep(nanoseconds: 800_000_000)

            assertTest(
                coletorChat.recebidas.count == recebidasAntes,
                "Chat desligado: mensagem de cliente adulterado não chega ao professor"
            )

            // E religar volta a funcionar — o bloqueio não pode deixar o chat morto de vez.
            servidorChat.isChatEnabled = true
            try? await alunoA.send(.string("{\"type\":\"CHAT_SEND\",\"payload\":{\"sender\":\"Ana\",\"text\":\"agora vai\"}}"))
            try? await Task.sleep(nanoseconds: 800_000_000)

            assertTest(
                coletorChat.recebidas.last?.text == "agora vai",
                "Religar o chat volta a entregar as mensagens ao professor"
            )

            alunoA.cancel(with: .goingAway, reason: nil)
            alunoB.cancel(with: .goingAway, reason: nil)
            servidorChat.stop()
        } catch {
            assertTest(false, "Falha no teste de privacidade do chat: \(error.localizedDescription)")
        }

        // TESTE 12: A permissão de Gravação de Tela e o "AO VIVO" mentiroso.
        //
        // O pior defeito que este projeto teve não avisava nada: sem permissão, a captura
        // falhava em silêncio, o servidor subia mesmo assim e a tela anunciava
        // "TRANSMITINDO AO VIVO" com o cronômetro correndo — enquanto a turma via uma
        // imagem vazia. Erro que não parece erro é o que mais custa caro na aula.
        print("\n--- [12/13] Testes de Domínio: permissão de Gravação de Tela ---")


        let (vmSemPermissao, capturaSemPermissao, servidorSemPermissao) = montarVM(permissao: false)
        vmSemPermissao.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)

        assertTest(!vmSemPermissao.isStreaming, "Sem permissão, o app NÃO se declara no ar")
        assertTest(!servidorSemPermissao.isRunning, "Sem permissão, o servidor nem chega a subir")
        assertTest(!capturaSemPermissao.isRecording, "Sem permissão, a captura não é iniciada")
        assertTest(
            vmSemPermissao.needsScreenRecordingPermission,
            "Sem permissão, o painel passa a mostrar o caminho da autorização"
        )
        assertTest(
            (vmSemPermissao.permission as? FakePermission)?.pedidosFeitos == 1,
            "Sem permissão, quem exibe o pedido é o macOS (request chamado uma vez)"
        )

        // O looping que o professor via: cada clique em "Iniciar Transmissão" reabria o aviso
        // do macOS, porque a permissão continua indisponível até o app ser reaberto. O pedido
        // tem que acontecer uma vez por execução, e não uma vez por clique.
        vmSemPermissao.startStream()
        try? await Task.sleep(nanoseconds: 300_000_000)
        vmSemPermissao.startStream()
        try? await Task.sleep(nanoseconds: 300_000_000)

        assertTest(
            (vmSemPermissao.permission as? FakePermission)?.pedidosFeitos == 1,
            "Clicar de novo NÃO reabre o aviso do macOS (fim do looping)"
        )
        assertTest(
            vmSemPermissao.streamErrorMessage?.contains("reabra") == true,
            "A partir da segunda tentativa, o recado passa a ser reabrir o aplicativo"
        )
        assertTest(
            vmSemPermissao.streamErrorMessage != nil,
            "Sem permissão, o professor recebe uma explicação em vez de silêncio"
        )
        assertTest(vmSemPermissao.streamStartedAt == nil, "Sem permissão, nenhum cronômetro começa a correr")

        // Permissão concedida nos Ajustes, mas o processo antigo continua sem enxergar a
        // tela: é o caso de quem clicou "Mais Tarde" no aviso de reabrir do macOS.
        let (vmCapturaFalha, _, servidorCapturaFalha) = montarVM(permissao: true, capturaFalha: true)
        vmCapturaFalha.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)

        assertTest(!vmCapturaFalha.isStreaming, "Captura que não sobe não vira transmissão anunciada")
        assertTest(!servidorCapturaFalha.isRunning, "Captura que não sobe não deixa servidor aberto para trás")
        assertTest(
            vmCapturaFalha.streamErrorMessage?.contains("permissão") == true,
            "A falha real da captura chega ao professor com o motivo"
        )

        // E o caminho feliz precisa continuar funcionando.
        let (vmOk, capturaOk, servidorOk) = montarVM(permissao: true)
        vmOk.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)

        assertTest(vmOk.isStreaming, "Com permissão e captura ok, a transmissão começa")
        assertTest(servidorOk.isRunning, "Com permissão e captura ok, o servidor sobe")
        assertTest(capturaOk.isRecording, "Com permissão e captura ok, a captura roda")
        assertTest(vmOk.streamErrorMessage == nil, "Caminho feliz não deixa mensagem de erro na tela")
        assertTest(
            !vmOk.needsScreenRecordingPermission,
            "Caminho feliz não pede autorização"
        )

        // Autorizou e reabriu: o recado da tentativa anterior não pode ficar preso na tela.
        let (vmDepois, _, _) = montarVM(permissao: false)
        vmDepois.startStream()
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTest(vmDepois.needsScreenRecordingPermission, "Primeira tentativa marca a falta de autorização")

        (vmDepois.permission as? FakePermission)?.concedida = true
        vmDepois.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)

        assertTest(vmDepois.isStreaming, "Depois de autorizar, a mesma tentativa transmite")
        assertTest(
            !vmDepois.needsScreenRecordingPermission,
            "Depois de autorizar, o recado de permissão some do painel"
        )

        // TESTE 13: Proteção contra o estrangulamento do macOS (App Nap).
        // Ao trocar de Mesa ou mudar de aplicativo, o AulaCast sai de vista e o sistema
        // passaria a atrasar seus temporizadores — travando a transmissão justamente quando
        // o professor vai demonstrar algo em outro app.
        print("\n--- [13/13] Testes de Domínio: proteção contra App Nap ---")

        // O serviço real primeiro: é o contrato que o dublê abaixo espelha. Ele guarda um
        // único token, então pedir duas vezes não acumula nada e um único "soltar" libera.
        let atividadeReal = SystemActivityService()
        assertTest(!atividadeReal.isHoldingActivity, "Serviço real começa sem segurar nada")

        atividadeReal.beginTransmission(reason: "Teste de proteção")
        atividadeReal.beginTransmission(reason: "Teste de proteção")
        assertTest(atividadeReal.isHoldingActivity, "Serviço real segura a proteção ao transmitir")

        atividadeReal.endTransmission()
        assertTest(
            !atividadeReal.isHoldingActivity,
            "Pedir duas vezes não acumula: um único 'soltar' libera o Mac"
        )

        let atividade = FakeSystemActivity()
        let vmAtividade = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: FakeServer(),
            advertiserService: FakeAdvertiser(),
            systemActivity: atividade
        )

        assertTest(!atividade.isHoldingActivity, "Parado, o app não segura nenhuma proteção")

        vmAtividade.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(atividade.isHoldingActivity, "Transmitindo, a proteção contra App Nap fica ativa")
        assertTest(atividade.inicios == 1, "A proteção é solicitada uma única vez")
        assertTest(vmAtividade.isSessionOpen, "Transmitindo, a sessão consta como aberta")
        assertTest(
            atividade.ultimaRazao?.isEmpty == false,
            "A razão é informada ao sistema (aparece em diagnósticos de energia)"
        )

        vmAtividade.stopStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(!atividade.isHoldingActivity, "Ao parar, a proteção é liberada")

        // Caminho crítico: a captura morre sozinha, mas o servidor segue no ar de propósito
        // e a turma continua conectada.
        //
        // A proteção era liberada aqui, e isso desfazia justamente o motivo de manter o
        // servidor de pé: numa máquina configurada para dormir com 1 minuto de ociosidade
        // (o padrão é apertado), o Mac dormia logo depois da queda, todas as conexões caíam
        // e os alunos iam parar em "Reconectando" enquanto o professor ainda lia o aviso.
        // Quem encerra a sessão de verdade é "Parar Transmissão".
        let atividadeQueda = FakeSystemActivity()
        let servidorQueda = FakeServer()
        let vmQueda = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorQueda,
            advertiserService: FakeAdvertiser(),
            systemActivity: atividadeQueda
        )

        vmQueda.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(atividadeQueda.isHoldingActivity, "Proteção ativa antes da queda")

        vmQueda.captureDidStopUnexpectedly(reason: "O monitor foi desconectado.")
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTest(
            servidorQueda.isRunning,
            "Depois da queda o servidor segue no ar, com a turma conectada"
        )
        assertTest(
            atividadeQueda.isHoldingActivity,
            "Com alunos ainda conectados, o Mac continua impedido de dormir"
        )
        assertTest(
            vmQueda.isSessionOpen && !vmQueda.isStreaming,
            "Depois da queda a sessão segue aberta, e o painel oferece como encerrá-la"
        )

        // E a proteção não fica pendurada para sempre: encerrar a transmissão a libera.
        vmQueda.stopStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(
            !atividadeQueda.isHoldingActivity,
            "Parar a transmissão libera a proteção (o Mac volta a poder dormir)"
        )
        assertTest(
            !servidorQueda.isRunning,
            "Parar a transmissão também baixa o servidor"
        )
        assertTest(!vmQueda.isSessionOpen, "Encerrada a sessão, o botão de encerrar some")

        // Reiniciar depois da queda não pode acumular uma segunda proteção.
        let atividadeRetomada = FakeSystemActivity()
        let vmRetomadaAtividade = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: FakeServer(),
            advertiserService: FakeAdvertiser(),
            systemActivity: atividadeRetomada
        )
        vmRetomadaAtividade.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        vmRetomadaAtividade.captureDidStopUnexpectedly(reason: "O monitor foi desconectado.")
        try? await Task.sleep(nanoseconds: 200_000_000)
        vmRetomadaAtividade.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)

        vmRetomadaAtividade.stopStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(
            !atividadeRetomada.isHoldingActivity,
            "Depois de cair e voltar, um único 'Parar' libera a proteção (nada acumulado)"
        )

        } else { placar.puladas.append("T10b-T13 prévia/chat/permissão/App Nap (sleeps)") }

        // TESTE 14: Mensagem partida em vários frames e mensagem longa demais.
        //
        // O navegador parte mensagens grandes em vários frames (o primeiro com FIN=0, os
        // seguintes com opcode 0). Tratar cada frame como uma mensagem inteira entregava ao
        // professor só o começo do texto do aluno e jogava o resto fora sem aviso nenhum.
        print("\n--- [14/16] Testes de Protocolo: mensagens partidas e longas ---")

        func frameMascarado(opcode: UInt8, fin: Bool, texto: String) -> Data {
            let payload = Array(texto.utf8)
            let mascara: [UInt8] = [0x1A, 0x2B, 0x3C, 0x4D]
            var frame = Data([(fin ? 0x80 : 0x00) | opcode, UInt8(0x80 | payload.count)])
            frame.append(contentsOf: mascara)
            for (i, b) in payload.enumerated() {
                frame.append(b ^ mascara[i % 4])
            }
            return frame
        }

        func textoDoUnicoFrame(_ resultado: WebSocketFrameDecoder.Result) -> String? {
            guard case .frames(let lista) = resultado, lista.count == 1 else { return nil }
            return String(data: lista[0].payload, encoding: .utf8)
        }

        let decodificadorPartes = WebSocketFrameDecoder()
        var partida = frameMascarado(opcode: 0x1, fin: false, texto: "Professor, não consigo ")
        partida.append(frameMascarado(opcode: 0x0, fin: false, texto: "enxergar o terminal "))
        partida.append(frameMascarado(opcode: 0x0, fin: true, texto: "daqui de trás."))

        assertTest(
            textoDoUnicoFrame(decodificadorPartes.consume(partida))
                == "Professor, não consigo enxergar o terminal daqui de trás.",
            "Mensagem partida em três frames chega inteira ao professor"
        )

        // Um ping do navegador pode cair no meio de uma mensagem partida sem atrapalhá-la.
        let decodificadorComPing = WebSocketFrameDecoder()
        var comPing = frameMascarado(opcode: 0x1, fin: false, texto: "metade ")
        comPing.append(Data([0x89, 0x80, 0x00, 0x00, 0x00, 0x00])) // PING mascarado, sem payload
        comPing.append(frameMascarado(opcode: 0x0, fin: true, texto: "e metade"))

        if case .frames(let lista) = decodificadorComPing.consume(comPing) {
            let textos = lista.compactMap { $0.isText ? String(data: $0.payload, encoding: .utf8) : nil }
            assertTest(lista.count == 2, "Ping no meio da mensagem partida não some nem atrapalha")
            assertTest(textos == ["metade e metade"], "Mensagem partida ao redor do ping é remontada")
        } else {
            assertTest(false, "Ping no meio da mensagem partida não some nem atrapalha")
        }

        // Continuação sem começo é cliente adulterado (ou fora de sincronia): encerrar.
        let orfa = WebSocketFrameDecoder().consume(frameMascarado(opcode: 0x0, fin: true, texto: "sem começo"))
        assertTest(orfa == .protocolViolation, "Frame de continuação sem começo é recusado")

        // Mensagem do professor acima de 64 KB: antes o frame simplesmente não era montado
        // e a turma nunca recebia nada — sem erro em lugar nenhum.
        let textoLongo = String(repeating: "Resumo da aula. ", count: 8_000) // ~128 KB
        assertTest(textoLongo.utf8.count > 65_535, "O texto de teste passa mesmo dos 64 KB")

        let frameLongo = WebSocketFrameEncoder.textFrame(textoLongo)
        let decodificadorLongo = WebSocketFrameDecoder(maxPayloadBytes: 1 << 22)
        assertTest(
            textoDoUnicoFrame(decodificadorLongo.consume(frameLongo)) == textoLongo,
            "Mensagem acima de 64 KB é montada e chega inteira (antes era descartada em silêncio)"
        )

        // Os três tamanhos de cabeçalho da RFC 6455.
        assertTest(
            WebSocketFrameEncoder.textFrame("oi").count == 2 + 2,
            "Texto curto usa cabeçalho de 2 bytes"
        )
        assertTest(
            WebSocketFrameEncoder.textFrame(String(repeating: "a", count: 300)).count == 4 + 300,
            "Texto médio usa comprimento estendido de 2 bytes"
        )
        assertTest(
            WebSocketFrameEncoder.pongFrame(payload: Data([0x01, 0x02])).first == 0x8A,
            "Pong é frame de controle (opcode 0xA), e não texto"
        )

        if executarTudo {
        // TESTE 15: O servidor que precisa continuar de pé entre uma queda e a volta da aula.
        print("\n--- [15/16] Testes de Rede: reinício e requisição partida ---")

        final class ColetorDeSaidas: ClientObserverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _entradas: [String] = []
            private var _saidas: [String] = []

            var entradas: [String] { trava.lock(); defer { trava.unlock() }; return _entradas }
            var saidas: [String] { trava.lock(); defer { trava.unlock() }; return _saidas }

            func didClientConnect(_ client: ConnectedClient) {
                trava.lock(); _entradas.append(client.id); trava.unlock()
            }
            func didClientDisconnect(clientId: String) {
                trava.lock(); _saidas.append(clientId); trava.unlock()
            }
        }

        /// Abre uma conexão TCP crua e envia a requisição em duas partes, com uma pausa no
        /// meio — é o que a rede da escola faz sozinha quando o pacote chega picado.
        func requisicaoEmDuasPartes(porta: UInt16, primeira: String, segunda: String) async -> String {
            final class Caixa: @unchecked Sendable {
                private let trava = NSLock()
                private var dados = Data()
                func acrescentar(_ novos: Data) { trava.lock(); dados.append(novos); trava.unlock() }
                var texto: String {
                    trava.lock(); defer { trava.unlock() }
                    return String(data: dados, encoding: .utf8) ?? ""
                }
            }

            let caixa = Caixa()
            let conexao = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: porta)!,
                using: .tcp
            )
            conexao.start(queue: .global(qos: .userInitiated))
            try? await Task.sleep(nanoseconds: 300_000_000)

            conexao.receive(minimumIncompleteLength: 1, maximumLength: 8192) { dados, _, _, _ in
                if let dados = dados { caixa.acrescentar(dados) }
            }

            conexao.send(content: Data(primeira.utf8), completion: .contentProcessed({ _ in }))
            try? await Task.sleep(nanoseconds: 250_000_000)
            conexao.send(content: Data(segunda.utf8), completion: .contentProcessed({ _ in }))
            try? await Task.sleep(nanoseconds: 600_000_000)

            conexao.cancel()
            return caixa.texto
        }

        let saidas = ColetorDeSaidas()
        let servidorReinicio = NetworkListenerService(
            port: 8102,
            webAssetsPath: FileManager.default.temporaryDirectory
        )
        servidorReinicio.clientObserver = saidas

        do {
            try servidorReinicio.start()

            // O caminho real: a captura cai, o servidor segue no ar de propósito para avisar
            // a turma, e o professor clica em "Iniciar Transmissão" de novo. Subir um segundo
            // listener na mesma porta derrubava o servidor em silêncio — o app continuava
            // anunciando "AO VIVO" e nenhum aluno conseguia mais entrar.
            try servidorReinicio.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            assertTest(servidorReinicio.isRunning, "Reiniciar a transmissão não derruba o servidor")

            let socketDepoisDoReinicio = URLSession.shared.webSocketTask(
                with: URL(string: "ws://127.0.0.1:8102/ws")!
            )
            socketDepoisDoReinicio.resume()
            var reconectou = false
            if case .string(let texto)? = try? await socketDepoisDoReinicio.receive() {
                reconectou = texto.contains("CONNECTED")
            }
            assertTest(reconectou, "Depois do reinício o aluno ainda consegue entrar na aula")

            // A saída do aluno chega por dois caminhos (o frame de CLOSE e a falha da escuta
            // logo depois). Avisar nos dois tirava o mesmo aluno da lista duas vezes.
            let idDoAluno = saidas.entradas.last
            socketDepoisDoReinicio.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(nanoseconds: 700_000_000)

            let saidasDoAluno = saidas.saidas.filter { $0 == idDoAluno }
            assertTest(
                saidasDoAluno.count == 1,
                "Aluno que sai é anunciado uma única vez (anunciados: \(saidasDoAluno.count))"
            )

            // Requisição partida em duas leituras: o cabeçalho Upgrade só chega na segunda.
            // Decidindo na primeira leitura, o handshake caía no servidor de arquivos e o
            // aluno recebia 404 no lugar da aula.
            let resposta = await requisicaoEmDuasPartes(
                porta: 8102,
                primeira: "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:8102\r\nUpgr",
                segunda: "ade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
            )
            assertTest(
                resposta.contains("101 Switching Protocols"),
                "Handshake partido entre duas leituras ainda é reconhecido"
            )
            assertTest(
                resposta.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
                "A chave de aceitação do handshake partido é a da RFC 6455"
            )

            servidorReinicio.stop()
        } catch {
            assertTest(false, "Falha no teste de reinício do servidor: \(error.localizedDescription)")
        }

        // Porta já ocupada por outro aplicativo: o socket falha depois, de forma assíncrona,
        // então `start()` não lança nada. Sem alguém escutando o estado do listener, o app
        // seguia anunciando "TRANSMITINDO AO VIVO" com o servidor morto e nenhum aluno
        // conseguindo entrar — o professor só descobria pela turma.
        do {
            let intruso = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 8103)!)
            intruso.newConnectionHandler = { $0.cancel() }
            intruso.start(queue: .global(qos: .utility))
            try? await Task.sleep(nanoseconds: 400_000_000)

            let servidorSemPorta = NetworkListenerService(
                port: 8103,
                webAssetsPath: FileManager.default.temporaryDirectory
            )
            try servidorSemPorta.start()
            try? await Task.sleep(nanoseconds: 800_000_000)

            assertTest(
                !servidorSemPorta.isRunning,
                "Porta ocupada por outro app derruba o 'no ar' em vez de mentir para o professor"
            )

            servidorSemPorta.stop()
            intruso.cancel()
        } catch {
            assertTest(false, "Falha no teste de porta ocupada: \(error.localizedDescription)")
        }

        // TESTE 16: A aula que volta e o custo das miniaturas.
        print("\n--- [16/16] Testes de Domínio: retomada da aula e miniaturas ---")

        let (vmRetomada, _, servidorRetomada) = montarVM(permissao: true)
        vmRetomada.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)

        vmRetomada.captureDidStopUnexpectedly(reason: "O monitor foi desconectado.")
        try? await Task.sleep(nanoseconds: 200_000_000)

        assertTest(
            servidorRetomada.controlMessages.contains { $0.type == "STREAM_ENDED" },
            "A queda da captura é anunciada à turma"
        )
        assertTest(
            servidorRetomada.isRunning,
            "O servidor continua no ar depois da queda, para a turma receber o aviso"
        )

        // Aqui morava o defeito: o WebSocket nunca caiu, então nada avisava os alunos de que
        // a aula tinha voltado. A turma inteira ficava na tela de "Transmissão encerrada"
        // com o professor já transmitindo, e só recarregar a página resolvia.
        vmRetomada.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)

        assertTest(vmRetomada.isStreaming, "Depois da queda, o professor consegue transmitir de novo")

        let tiposAnunciados = servidorRetomada.controlMessages.map { $0.type }
        assertTest(
            tiposAnunciados.contains("STREAM_STARTED"),
            "A volta da transmissão é anunciada aos alunos que continuaram conectados"
        )
        if let posicaoDaQueda = tiposAnunciados.firstIndex(of: "STREAM_ENDED"),
           let posicaoDaVolta = tiposAnunciados.lastIndex(of: "STREAM_STARTED") {
            assertTest(
                posicaoDaVolta > posicaoDaQueda,
                "O aviso de volta vem depois do aviso de queda (é ele que destrava a tela do aluno)"
            )
        } else {
            assertTest(false, "O aviso de volta vem depois do aviso de queda")
        }

        // Histórico permanente de alunos: uma retomada depois da captura cair (servidor
        // nunca desceu, mesma sessão) não pode zerar quem já entrou — só encerrar a
        // sessão de vez e começar outra aula zera.
        let alunoDaRetomada = ConnectedClient(name: "Aluno-9.9", ipAddress: "192.168.9.9")
        vmRetomada.didClientConnect(alunoDaRetomada)
        try? await Task.sleep(nanoseconds: 150_000_000)
        vmRetomada.didIdentifyStudent(clientId: alunoDaRetomada.id, name: "Fábio")
        try? await Task.sleep(nanoseconds: 150_000_000)
        assertTest(
            vmRetomada.clientManager.totalIdentificadosNaAula == 1,
            "Aluno identificado depois da retomada entra no histórico da aula"
        )

        vmRetomada.stopStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        vmRetomada.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(
            vmRetomada.clientManager.totalIdentificadosNaAula == 0,
            "Encerrar a sessão de vez e começar outra aula zera o histórico permanente"
        )

        // Miniatura das fontes: guardar o quadro em resolução nativa não melhora nada na
        // tela e cobra caro — uma varredura com dez janelas num monitor 5K são dez imagens
        // enormes recriadas a cada cinco segundos, disputando a CPU com a transmissão.
        let miniatura5K = SourceThumbnailProvider.tamanhoExibido(largura: 5120, altura: 2880)
        assertTest(
            miniatura5K.width == SourceThumbnailProvider.larguraMaxima,
            "Miniatura de monitor 5K respeita o teto de largura"
        )
        assertTest(
            Int(miniatura5K.height) == 540,
            "Miniatura reduzida mantém a proporção do monitor (altura: \(Int(miniatura5K.height)))"
        )

        let miniaturaPequena = SourceThumbnailProvider.tamanhoExibido(largura: 640, altura: 400)
        assertTest(
            miniaturaPequena.width == 640 && miniaturaPequena.height == 400,
            "Janela menor que o teto não é ampliada à toa"
        )

        // TESTE 17: Homônimos, histórico do chat e o aluno que fecha a aba.
        print("\n--- [17/17] Testes de Domínio: turma cheia e aula longa ---")

        // Numa turma real há homônimos — e, antes de se identificarem, todos os alunos se
        // chamam "Aluno-…". A saída de um deles não pode levar junto o colega de mesmo nome.
        let gerenciadorHomonimos = ClientManagerService()
        let primeiraAna = ConnectedClient(name: "Ana", ipAddress: "192.168.1.20")
        let segundaAna = ConnectedClient(name: "Ana", ipAddress: "192.168.1.21")
        gerenciadorHomonimos.addOrUpdateClient(primeiraAna)
        gerenciadorHomonimos.addOrUpdateClient(segundaAna)

        gerenciadorHomonimos.removeClient(id: segundaAna.id)
        assertTest(
            gerenciadorHomonimos.clients.count == 1,
            "Sai exatamente um aluno quando dois têm o mesmo nome"
        )
        assertTest(
            gerenciadorHomonimos.clients.first?.id == primeiraAna.id,
            "Quem sai é o dono da conexão que caiu, e não o primeiro homônimo da lista"
        )

        // Um id que não existe (ou um nome no lugar do id) não pode remover ninguém.
        gerenciadorHomonimos.removeClient(id: "Ana")
        assertTest(
            gerenciadorHomonimos.clients.count == 1,
            "Remover por nome não tira aluno nenhum da lista"
        )

        // Aula longa com turma cheia: o histórico não pode crescer para sempre.
        let chatLongo = ChatManagerService()
        for i in 1...(ChatManagerService.maxMessages + 120) {
            chatLongo.addMessage(ChatMessage(sender: "Aluno \(i)", text: "Mensagem \(i)", isProf: false))
        }
        assertTest(
            chatLongo.messages.count == ChatManagerService.maxMessages,
            "Histórico do chat respeita o teto (guardadas: \(chatLongo.messages.count))"
        )
        assertTest(
            chatLongo.messages.last?.text == "Mensagem \(ChatManagerService.maxMessages + 120)",
            "O que fica é o fim da conversa, que é o que o professor está lendo"
        )
        assertTest(
            chatLongo.messages.first?.text == "Mensagem 121",
            "O descarte tira as mensagens mais antigas, em ordem"
        )

        // O aluno que fecha a aba com a tela do professor parada.
        //
        // Sem envio não há erro de envio, e era só pelo erro de envio que a saída era
        // percebida: a conexão de vídeo ficava pendurada, girando o laço a cada 10 ms, até
        // que um quadro novo finalmente falhasse. Uma por aluno que saiu.
        let servidorVideo = NetworkListenerService(
            port: 8104,
            webAssetsPath: FileManager.default.temporaryDirectory
        )

        do {
            try servidorVideo.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            // De propósito, nenhum quadro é publicado: é o cenário da tela parada.
            let video = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 8104)!,
                using: .tcp
            )
            video.start(queue: .global(qos: .userInitiated))
            try? await Task.sleep(nanoseconds: 300_000_000)

            video.send(
                content: Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:8104\r\n\r\n".utf8),
                completion: .contentProcessed({ _ in })
            )
            try? await Task.sleep(nanoseconds: 600_000_000)

            assertTest(servidorVideo.activeStreamCount == 1, "O vídeo do aluno é contado enquanto está aberto")

            video.cancel()

            // Dá tempo de a saída ser percebida — sem nenhum quadro novo no meio.
            var sobrou = servidorVideo.activeStreamCount
            for _ in 0..<10 where sobrou > 0 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                sobrou = servidorVideo.activeStreamCount
            }

            assertTest(
                sobrou == 0,
                "Aluno que fecha a aba com a tela parada não deixa conexão pendurada (sobraram: \(sobrou))"
            )

            servidorVideo.stop()
        } catch {
            assertTest(false, "Falha no teste do stream de vídeo: \(error.localizedDescription)")
        }

        } else { placar.puladas.append("T15-T17 reinício/retomada/turma cheia") }

        // TESTE 18: Qual endereço o professor passa para a turma.
        //
        // O painel lia o IP uma única vez, na abertura, e só olhava en0/en1. Quem abrisse o
        // aplicativo em casa e chegasse na escola via o endereço de casa; quem usasse cabo ou
        // adaptador USB-C (que vira en2 ou acima) via 127.0.0.1 — nenhum dos dois leva aluno
        // a lugar nenhum, e nada na tela avisava que o número estava errado.
        print("\n--- [18/18] Testes de Rede: endereço mostrado à turma ---")

        typealias Interface = NetworkListenerService.InterfaceDeRede

        // O caso da escola: Wi-Fi e um monte de interface de sistema no ar ao mesmo tempo.
        let salaDeAula = [
            Interface(nome: "utun0", ip: "10.8.0.2"),
            Interface(nome: "awdl0", ip: "169.254.31.4"),
            Interface(nome: "en0", ip: "192.168.0.42"),
            Interface(nome: "llw0", ip: "169.254.9.9")
        ]
        assertTest(
            NetworkListenerService.melhorEndereco(entre: salaDeAula, interfaceWiFi: "en0") == "192.168.0.42",
            "Com Wi-Fi no ar, é o endereço do Wi-Fi que vai para a turma"
        )

        // VPN ligada não pode roubar a vez: o aluno não chega pelo túnel.
        assertTest(
            NetworkListenerService.melhorEndereco(
                entre: [Interface(nome: "utun3", ip: "10.8.0.2"), Interface(nome: "en0", ip: "192.168.0.42")],
                interfaceWiFi: "en0"
            ) == "192.168.0.42",
            "VPN ativa não vira o endereço da aula"
        )

        // Cabo de rede num adaptador USB-C: o sistema chama de en4, e antes isso virava
        // 127.0.0.1 na tela.
        assertTest(
            NetworkListenerService.melhorEndereco(
                entre: [Interface(nome: "en4", ip: "10.0.0.7")],
                interfaceWiFi: nil
            ) == "10.0.0.7",
            "Cabo em adaptador (en4) é reconhecido em vez de virar 127.0.0.1"
        )

        // Nem todo Mac chama o Wi-Fi de en0 — quem diz é o sistema, não o nome.
        assertTest(
            NetworkListenerService.melhorEndereco(
                entre: [Interface(nome: "en0", ip: "10.0.0.7"), Interface(nome: "en1", ip: "192.168.15.30")],
                interfaceWiFi: "en1"
            ) == "192.168.15.30",
            "O Wi-Fi apontado pelo sistema ganha de en0 pelo nome"
        )

        // Endereço auto-atribuído quer dizer "não falei com o roteador": mostrar isso é pior que
        // não mostrar nada, porque tem cara de endereço bom.
        assertTest(
            NetworkListenerService.melhorEndereco(
                entre: [Interface(nome: "en0", ip: "169.254.10.1")],
                interfaceWiFi: "en0"
            ) == nil,
            "Endereço auto-atribuído (169.254) não é oferecido à turma"
        )

        assertTest(
            NetworkListenerService.melhorEndereco(entre: [], interfaceWiFi: nil) == nil,
            "Sem interface no ar, não há endereço a mostrar"
        )

        // E o principal: o endereço é lido na hora, não guardado na abertura.
        let servidorEndereco = NetworkListenerService(
            port: 8105,
            webAssetsPath: FileManager.default.temporaryDirectory
        )
        let interfacesReais = NetworkListenerService.interfacesAtivas()
        assertTest(
            !interfacesReais.isEmpty,
            "A varredura enxerga as interfaces reais desta máquina (achadas: \(interfacesReais.count))"
        )
        assertTest(
            servidorEndereco.localIPAddress == (NetworkListenerService.enderecoLocal() ?? "127.0.0.1"),
            "O endereço do painel é consultado na hora, e não congelado na abertura"
        )

        if executarTudo {
        // TESTE 19: O quadro sai assim que fica pronto.
        //
        // A conexão de vídeo fica parada esperando o próximo quadro. Antes essa espera era
        // um cochilo de 10 ms — o laço acordava, perguntava se havia algo novo e dormia de
        // novo — o que encaixava a saída dos quadros numa grade de 10 ms. Agora quem publica
        // o quadro acorda as conexões paradas, e o risco passa a ser outro: perder o aviso e
        // deixar o aluno dormindo. É isso que este teste vigia.
        print("\n--- [19/19] Testes de Rede: entrega dos quadros ---")

        let servidorFluidez = NetworkListenerService(
            port: 8106,
            webAssetsPath: FileManager.default.temporaryDirectory
        )

        do {
            try servidorFluidez.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            final class BytesRecebidos: @unchecked Sendable {
                private let trava = NSLock()
                private var total = 0
                func somar(_ quantos: Int) { trava.lock(); total += quantos; trava.unlock() }
                var quantidade: Int { trava.lock(); defer { trava.unlock() }; return total }

                /// Lê a conexão até ela fechar. Fica aqui, e não numa função local do teste,
                /// porque o callback roda na fila da rede: uma função local herdaria o ator
                /// principal do teste, e o Swift 6 avisa da chamada fora dele.
                func escutar(_ conexao: NWConnection) {
                    conexao.receive(minimumIncompleteLength: 1, maximumLength: 65536) { dados, _, _, erro in
                        guard erro == nil else { return }
                        if let dados = dados { self.somar(dados.count) }
                        self.escutar(conexao)
                    }
                }
            }

            let recebidos = BytesRecebidos()
            let video = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 8106)!,
                using: .tcp
            )

            video.start(queue: .global(qos: .userInitiated))
            try? await Task.sleep(nanoseconds: 300_000_000)
            recebidos.escutar(video)

            video.send(
                content: Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:8106\r\n\r\n".utf8),
                completion: .contentProcessed({ _ in })
            )
            try? await Task.sleep(nanoseconds: 500_000_000)

            let apenasCabecalhos = recebidos.quantidade
            assertTest(apenasCabecalhos > 0, "O aluno recebe os cabeçalhos do stream ao pedir /stream")

            // A conexão está parada, sem nenhum quadro publicado até aqui: é exatamente a
            // situação em que um aviso perdido deixaria o aluno esperando para sempre.
            let primeiroQuadro = Data(repeating: 0xAB, count: 4096)
            servidorFluidez.broadcastFrame(primeiroQuadro)
            try? await Task.sleep(nanoseconds: 400_000_000)

            let depoisDoPrimeiro = recebidos.quantidade
            assertTest(
                depoisDoPrimeiro >= apenasCabecalhos + primeiroQuadro.count,
                "Quadro publicado com a conexão parada é entregue (recebidos: \(depoisDoPrimeiro - apenasCabecalhos) bytes)"
            )

            // E o laço volta a se registrar: o segundo quadro não pode ficar preso.
            let segundoQuadro = Data(repeating: 0xCD, count: 4096)
            servidorFluidez.broadcastFrame(segundoQuadro)
            try? await Task.sleep(nanoseconds: 400_000_000)

            assertTest(
                recebidos.quantidade >= depoisDoPrimeiro + segundoQuadro.count,
                "O quadro seguinte também sai, sem a conexão ficar dormindo"
            )

            video.cancel()
            servidorFluidez.stop()
        } catch {
            assertTest(false, "Falha no teste de entrega de quadros: \(error.localizedDescription)")
        }

        // TESTE 20: Início e queda do servidor.
        print("\n--- [20/20] Testes de Domínio: duplo clique, porta ocupada e aba fechada ---")

        let capturaLenta = FakeCaptureService()
        capturaLenta.atrasoAoIniciar = 300_000_000
        let vmDuploClique = MainViewModel(
            captureService: capturaLenta,
            encoderService: FakeEncoder(),
            serverService: FakeServer(),
            advertiserService: FakeAdvertiser(),
            systemActivity: FakeSystemActivity()
        )
        vmDuploClique.startStream()
        vmDuploClique.startStream()
        assertTest(vmDuploClique.isStarting, "Enquanto a captura sobe, o botão fica bloqueado")
        try? await Task.sleep(nanoseconds: 600_000_000)
        assertTest(capturaLenta.inicios == 1, "Duplo clique em Iniciar não cria uma segunda captura")
        assertTest(!vmDuploClique.isStarting, "Depois de subir, o botão volta a responder")

        let servidorQueCai = FakeServer()
        let atividadeDaPorta = FakeSystemActivity()
        let vmPorta = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorQueCai,
            advertiserService: FakeAdvertiser(),
            systemActivity: atividadeDaPorta
        )
        vmPorta.startStream()
        try? await Task.sleep(nanoseconds: 300_000_000)
        servidorQueCai.simularFalha("A porta 8080 já está em uso por outro aplicativo.")
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(!vmPorta.isStreaming, "Servidor que cai depois de subir tira o painel do 'AO VIVO'")
        assertTest(
            vmPorta.streamErrorMessage?.contains("em uso") == true,
            "O professor vê por que o servidor caiu"
        )
        assertTest(!atividadeDaPorta.isHoldingActivity, "Sem servidor, o Mac volta a poder dormir")

        // Aluno que fecha a aba com a tela parada: nada é enviado, então só a leitura
        // pendente percebe a saída. Um socket comum (e não o NWConnection do teste acima)
        // fecha com FIN, que é o que o navegador faz.
        let servidorAba = NetworkListenerService(port: 8113, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorAba.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var destino = sockaddr_in()
            destino.sin_family = sa_family_t(AF_INET)
            destino.sin_port = in_port_t(UInt16(8113).bigEndian)
            destino.sin_addr.s_addr = inet_addr("127.0.0.1")
            let conectou = withUnsafePointer(to: &destino) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let pedido = "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n"
            _ = pedido.withCString { send(fd, $0, strlen($0), 0) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            assertTest(conectou == 0 && servidorAba.activeStreamCount == 1, "O vídeo aberto por um socket comum é contado")

            // Lê os cabeçalhos antes de fechar, como o navegador: fechar com dados não lidos
            // manda RST em vez de FIN, e o RST o servidor já percebia sozinho.
            var lixo = [UInt8](repeating: 0, count: 4096)
            _ = recv(fd, &lixo, lixo.count, 0)
            close(fd)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            assertTest(
                servidorAba.activeStreamCount == 0,
                "Aba fechada com a tela parada libera a conexão do vídeo"
            )
            servidorAba.stop()
        } catch {
            assertTest(false, "Falha no teste da aba fechada: \(error.localizedDescription)")
        }

        } else { placar.puladas.append("T19-T20 quadros/porta ocupada") }

        // TESTE 21: A janela transmitida some.
        print("\n--- [21/21] Testes de Domínio: janela transmitida fechada ou minimizada ---")

        assertTest(
            !ScreenCaptureService.janelaExiste(CGWindowID(UInt32.max - 7)),
            "Janela que não existe é reconhecida como sumida"
        )

        let servidorDaJanela = FakeServer()
        let vmJanela = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorDaJanela,
            advertiserService: FakeAdvertiser(),
            systemActivity: FakeSystemActivity()
        )
        vmJanela.startStream()
        try? await Task.sleep(nanoseconds: 300_000_000)

        vmJanela.captureSourceDidDisappear(sourceName: "Visual Studio Code")
        assertTest(vmJanela.isPaused, "Janela sumiu: a turma recebe pausa em vez de imagem congelada")
        assertTest(vmJanela.isStreaming, "A sessão continua de pé para retomar sem reconectar a turma")
        assertTest(
            servidorDaJanela.controlMessages.last?.type == "STREAM_PAUSED",
            "Os alunos são avisados da pausa"
        )
        assertTest(
            vmJanela.streamErrorMessage?.contains("Visual Studio Code") == true,
            "O professor vê qual janela sumiu"
        )

        vmJanela.captureSourceIsAvailableAgain()
        assertTest(!vmJanela.isPaused, "A janela voltou (ou outra fonte foi escolhida): a aula retoma sozinha")
        assertTest(
            servidorDaJanela.controlMessages.last?.type == "STREAM_RESUMED",
            "Os alunos são avisados da volta"
        )
        assertTest(vmJanela.streamErrorMessage == nil, "O aviso some quando a aula volta")

        // Pausa posta pelo professor não é desfeita pelo app.
        vmJanela.togglePause()
        vmJanela.captureSourceIsAvailableAgain()
        assertTest(vmJanela.isPaused, "Pausa do professor não é desfeita quando uma janela volta")

        // Se o professor pausou antes de a janela sumir, a volta dela também não retoma.
        vmJanela.captureSourceDidDisappear(sourceName: "Safari")
        vmJanela.captureSourceIsAvailableAgain()
        assertTest(vmJanela.isPaused, "Com a aula já pausada pelo professor, a janela voltar não retoma")

        if executarTudo {
        // TESTE 22: Otimizações medidas contra as práticas consolidadas.
        print("\n--- [22/22] Testes: tamanho da captura, codificador e confirmação do quadro ---")

        // Tamanho da saída na proporção da fonte, sem faixas pretas e sem ampliar.
        let limite1080 = CGSize(width: 1920, height: 1080)
        let monitor1610 = ScreenCaptureService.tamanhoDeSaida(pixels: CGSize(width: 2940, height: 1912), limite: limite1080)
        assertTest(monitor1610 == (1660, 1080), "Monitor 16:10 sai em 1660x1080, sem faixas laterais")
        let janelaPequena = ScreenCaptureService.tamanhoDeSaida(pixels: CGSize(width: 1400, height: 1064), limite: limite1080)
        assertTest(janelaPequena == (1400, 1064), "Janela menor que o limite sai no tamanho dela, sem ampliar")
        let janelaEmPe = ScreenCaptureService.tamanhoDeSaida(pixels: CGSize(width: 1600, height: 2400), limite: limite1080)
        assertTest(janelaEmPe == (720, 1080), "Janela em pé cabe pela altura, mantendo a proporção")
        let em720 = ScreenCaptureService.tamanhoDeSaida(pixels: CGSize(width: 3840, height: 2160), limite: CGSize(width: 1280, height: 720))
        assertTest(em720 == (1280, 720), "Em 720p, um monitor 16:9 grande sai em 1280x720")

        // O codificador novo entrega JPEG de verdade a partir do pixel buffer da captura.
        final class ColetorDeJPEG: EncodedFrameReceiverProtocol, @unchecked Sendable {
            private let trava = NSLock(); private var _dados: Data?
            var dados: Data? { trava.lock(); defer { trava.unlock() }; return _dados }
            func didReceiveEncodedFrame(data: Data, isKeyFrame: Bool) { trava.lock(); _dados = data; trava.unlock() }
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        var formato: CMVideoFormatDescription?
        var amostra: CMSampleBuffer?
        if let buffer {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &formato)
            var tempo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            if let formato {
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: formato,
                                                         sampleTiming: &tempo, sampleBufferOut: &amostra)
            }
        }
        let coletorJPEG = ColetorDeJPEG()
        let codificador = MJPEGFrameEncoder()
        codificador.outputReceiver = coletorJPEG
        if let amostra { codificador.encode(sampleBuffer: amostra) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTest(coletorJPEG.dados?.prefix(2) == Data([0xFF, 0xD8]), "O codificador entrega um JPEG válido")
        assertTest(
            coletorJPEG.dados.flatMap { NSImage(data: $0) }?.size == NSSize(width: 320, height: 200),
            "O JPEG sai no tamanho do quadro capturado"
        )

        // O Safari só desenha um quadro quando o próximo chega: parada a tela, o último é
        // repetido uma vez para a turma ver o quadro certo.
        let servidorConfirma = NetworkListenerService(port: 8115, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorConfirma.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var destino = sockaddr_in()
            destino.sin_family = sa_family_t(AF_INET)
            destino.sin_port = in_port_t(UInt16(8115).bigEndian)
            destino.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &destino) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var espera = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &espera, socklen_t(MemoryLayout<timeval>.size))
            _ = "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n".withCString { send(fd, $0, strlen($0), 0) }
            try? await Task.sleep(nanoseconds: 200_000_000)

            servidorConfirma.broadcastFrame(Data(repeating: 0xAB, count: 1000))
            try? await Task.sleep(nanoseconds: 800_000_000)

            var recebido = Data()
            var pedaco = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(fd, &pedaco, pedaco.count, MSG_DONTWAIT)
                if n <= 0 { break }
                recebido.append(contentsOf: pedaco[0..<n])
            }
            let partes = (String(data: recebido, encoding: .isoLatin1) ?? "").components(separatedBy: "Content-Type: image/jpeg").count - 1
            assertTest(partes == 2, "Com a tela parada, o último quadro é repetido uma única vez (partes: \(partes))")
            close(fd)
            servidorConfirma.stop()
        } catch {
            assertTest(false, "Falha no teste de confirmação do quadro: \(error.localizedDescription)")
        }

        // TESTE 23: Arquivos compartilhados pelo professor.
        print("\n--- [23/23] Testes: compartilhamento de arquivos ---")

        let pastaDeArquivos = FileManager.default.temporaryDirectory
            .appendingPathComponent("aulacast_arquivos_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: pastaDeArquivos, withIntermediateDirectories: true)
        let apostila = pastaDeArquivos.appendingPathComponent("Apostila de Lógica – Aula 1.pdf")
        let conteudoApostila = Data((0..<5_000).map { UInt8($0 % 251) })
        try? conteudoApostila.write(to: apostila)
        // Maior que vários pedaços de 256 KB, para exercitar o envio em partes.
        let grande = pastaDeArquivos.appendingPathComponent("projeto.zip")
        let conteudoGrande = Data((0..<(5 * 1024 * 1024)).map { UInt8(($0 * 7) % 256) })
        try? conteudoGrande.write(to: grande)

        let servidorArquivos = FakeServer()
        let vmArquivos = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorArquivos,
            advertiserService: FakeAdvertiser(),
            systemActivity: FakeSystemActivity()
        )
        vmArquivos.shareFiles([apostila, grande, pastaDeArquivos, apostila])
        assertTest(vmArquivos.sharedFiles.count == 2, "Dois arquivos entram na lista; a pasta e a repetição ficam de fora")
        assertTest(vmArquivos.sharedFilesNotice?.contains(pastaDeArquivos.lastPathComponent) == true,
                   "O professor é avisado de que a pasta não foi compartilhada")
        assertTest(servidorArquivos.arquivosCompartilhados.count == 2, "A lista chega ao servidor")
        assertTest(vmArquivos.sharedFiles.first?.size == Int64(conteudoApostila.count), "O tamanho do arquivo é lido do disco")

        let servidorDownload = NetworkListenerService(port: 8116, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorDownload.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            // Quem já está conectado recebe a lista nova; quem chega depois, no CONNECTED.
            let socketArquivos = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8116/ws")!)
            socketArquivos.resume()
            await descartarBoasVindas(socketArquivos)
            servidorDownload.updateSharedFiles(vmArquivos.sharedFiles)
            var mensagemDeArquivos = ""
            if case .string(let texto)? = try? await socketArquivos.receive() { mensagemDeArquivos = texto }
            assertTest(mensagemDeArquivos.contains("\"FILES\"") && mensagemDeArquivos.contains("projeto.zip"),
                       "Quem está conectado recebe a lista de arquivos na hora")
            socketArquivos.cancel(with: .goingAway, reason: nil)

            let socketTardio = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8116/ws")!)
            socketTardio.resume()
            var boasVindasComArquivos = ""
            if case .string(let texto)? = try? await socketTardio.receive() { boasVindasComArquivos = texto }
            assertTest(boasVindasComArquivos.contains("projeto.zip"), "Quem entra depois já recebe a lista nas boas-vindas")
            socketTardio.cancel(with: .goingAway, reason: nil)

            func baixar(_ caminho: String) async -> (Data, HTTPURLResponse?) {
                guard let url = URL(string: "http://127.0.0.1:8116\(caminho)"),
                      let (dados, resposta) = try? await URLSession.shared.data(from: url) else { return (Data(), nil) }
                return (dados, resposta as? HTTPURLResponse)
            }

            let idApostila = vmArquivos.sharedFiles[0].id
            let (dadosApostila, respostaApostila) = await baixar("/arquivos/\(idApostila)")
            assertTest(respostaApostila?.statusCode == 200 && dadosApostila == conteudoApostila,
                       "O aluno baixa o arquivo idêntico ao do professor")
            let disposicao = respostaApostila?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            assertTest(disposicao.hasPrefix("attachment;"), "O navegador baixa o arquivo em vez de tentar abri-lo")
            assertTest(disposicao.contains("filename*=UTF-8''Apostila%20de%20L%C3%B3gica%20%E2%80%93%20Aula%201.pdf"),
                       "O nome com acento e travessão chega intacto ao aluno")
            assertTest(disposicao.contains("filename=\"Apostila de Logica _ Aula 1.pdf\""),
                       "Navegador antigo recebe um nome ASCII legível, sem os acentos")

            let (dadosGrandes, respostaGrande) = await baixar("/arquivos/\(vmArquivos.sharedFiles[1].id)")
            assertTest(respostaGrande?.statusCode == 200 && dadosGrandes == conteudoGrande,
                       "Arquivo de 5 MB chega inteiro, enviado em pedaços")

            let (_, respostaInexistente) = await baixar("/arquivos/\(UUID().uuidString)")
            assertTest(respostaInexistente?.statusCode == 404, "Id desconhecido não entrega nada")
            let (_, respostaTravessia) = await baixar("/arquivos/..%2F..%2Fetc%2Fpasswd")
            assertTest(respostaTravessia?.statusCode == 404, "Caminho no lugar do id não sai da lista de arquivos")

            vmArquivos.removeSharedFile(id: idApostila)
            servidorDownload.updateSharedFiles(vmArquivos.sharedFiles)
            let (_, respostaRemovido) = await baixar("/arquivos/\(idApostila)")
            assertTest(respostaRemovido?.statusCode == 404, "Arquivo que o professor tirou da lista deixa de ser baixável")

            try? FileManager.default.removeItem(at: grande)
            let (_, respostaApagado) = await baixar("/arquivos/\(vmArquivos.sharedFiles[0].id)")
            assertTest(respostaApagado?.statusCode == 404, "Arquivo apagado do disco responde 404, sem derrubar nada")

            servidorDownload.stop()
        } catch {
            assertTest(false, "Falha no teste de arquivos: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: pastaDeArquivos)

        } else { placar.puladas.append("T22-T23 codificador/arquivos") }

        // TESTE 24: Porta fixa, também no Bonjour.
        print("\n--- [24/24] Testes de Rede: anúncio Bonjour na porta do servidor ---")

        final class HospedeiroFalso: BonjourHostProtocol {
            var anuncios: [NWListener.Service?] = []
            func definirAnuncio(_ servico: NWListener.Service?) { anuncios.append(servico) }
        }
        let hospedeiro = HospedeiroFalso()
        let anunciante = BonjourAdvertiserService(servidor: hospedeiro)
        anunciante.startAdvertising()
        assertTest(
            hospedeiro.anuncios.last??.type == "_aulacast._tcp",
            "O anúncio sai pelo próprio servidor, com o tipo _aulacast._tcp"
        )
        anunciante.stopAdvertising()
        assertTest(hospedeiro.anuncios.count == 2 && hospedeiro.anuncios.last! == nil, "Parar desliga o anúncio")

        let vmPadrao = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: NetworkListenerService(port: 8114, webAssetsPath: FileManager.default.temporaryDirectory),
            systemActivity: FakeSystemActivity()
        )
        assertTest(
            vmPadrao.advertiserService is BonjourAdvertiserService,
            "O app anuncia pelo servidor da aula, sem um segundo listener em porta sorteada"
        )
        assertTest(vmPadrao.serverService.port == 8114, "A porta da turma é a que foi fixada")

        if executarTudo {
        // TESTE 25: O professor acompanha os downloads de cada arquivo.
        print("\n--- [25/25] Testes: acompanhamento dos downloads ---")

        final class ColetorDeDownloads: @unchecked Sendable {
            private let trava = NSLock(); private var _eventos: [FileDownloadStats] = []
            var eventos: [FileDownloadStats] { trava.lock(); defer { trava.unlock() }; return _eventos }
            func anotar(_ e: FileDownloadStats) { trava.lock(); _eventos.append(e); trava.unlock() }
        }
        let pastaDl = FileManager.default.temporaryDirectory.appendingPathComponent("aulacast_dl_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: pastaDl, withIntermediateDirectories: true)
        let arquivoDl = pastaDl.appendingPathComponent("material.zip")
        try? Data(repeating: 0x5A, count: 3 * 1024 * 1024).write(to: arquivoDl)
        let compartilhado = SharedFile(name: "material.zip", url: arquivoDl, size: 3 * 1024 * 1024)

        let servidorDl = NetworkListenerService(port: 8117, webAssetsPath: FileManager.default.temporaryDirectory)
        let coletorDl = ColetorDeDownloads()
        servidorDl.onFileDownloadUpdate = { coletorDl.anotar($0) }
        servidorDl.updateSharedFiles([compartilhado])
        do {
            try servidorDl.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let urlDl = URL(string: "http://127.0.0.1:8117/arquivos/\(compartilhado.id)")!

            _ = try? await URLSession.shared.data(from: urlDl)
            try? await Task.sleep(nanoseconds: 300_000_000)
            assertTest(coletorDl.eventos.first?.emAndamento == 1, "O professor vê o download começar")
            assertTest(coletorDl.eventos.last == FileDownloadStats(fileId: compartilhado.id, emAndamento: 0, concluidos: 1),
                       "Download completo: nada em andamento e 1 aluno com o arquivo")

            _ = try? await URLSession.shared.data(from: urlDl)
            try? await Task.sleep(nanoseconds: 300_000_000)
            assertTest(coletorDl.eventos.last?.concluidos == 1, "O mesmo aluno baixando de novo não conta duas vezes")

            // Download interrompido no meio: não conta como baixado.
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var destino = sockaddr_in()
            destino.sin_family = sa_family_t(AF_INET)
            destino.sin_port = in_port_t(UInt16(8117).bigEndian)
            destino.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &destino) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            _ = "GET /arquivos/\(compartilhado.id) HTTP/1.1\r\nHost: x\r\n\r\n".withCString { send(fd, $0, strlen($0), 0) }
            var pedaco = [UInt8](repeating: 0, count: 4096)
            _ = recv(fd, &pedaco, pedaco.count, 0)
            var linger_ = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger_, socklen_t(MemoryLayout<linger>.size))
            close(fd)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            assertTest(coletorDl.eventos.last?.emAndamento == 0, "Download interrompido sai de 'baixando'")
            assertTest(coletorDl.eventos.last?.concluidos == 1, "Download interrompido não conta como baixado")
            servidorDl.stop()
        } catch {
            assertTest(false, "Falha no teste de acompanhamento: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: pastaDl)

        // O painel só guarda contagem de arquivo que ainda está na lista.
        let servidorContagem = FakeServer()
        let vmContagem = MainViewModel(
            captureService: FakeCaptureService(), encoderService: FakeEncoder(),
            serverService: servidorContagem, advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity()
        )
        let pastaContagem = FileManager.default.temporaryDirectory.appendingPathComponent("aulacast_ct_\(UUID().uuidString).txt")
        try? Data("oi".utf8).write(to: pastaContagem)
        vmContagem.shareFiles([pastaContagem])
        let idContagem = vmContagem.sharedFiles.first?.id ?? ""
        servidorContagem.onFileDownloadUpdate?(FileDownloadStats(fileId: idContagem, emAndamento: 1, concluidos: 2))
        try? await Task.sleep(nanoseconds: 150_000_000)
        assertTest(vmContagem.fileDownloadStats[idContagem]?.concluidos == 2, "A contagem chega ao painel do professor")
        vmContagem.removeSharedFile(id: idContagem)
        servidorContagem.onFileDownloadUpdate?(FileDownloadStats(fileId: idContagem, emAndamento: 0, concluidos: 3))
        try? await Task.sleep(nanoseconds: 150_000_000)
        assertTest(vmContagem.fileDownloadStats[idContagem] == nil,
                   "Download que termina depois de o arquivo sair da lista não o traz de volta")
        try? FileManager.default.removeItem(at: pastaContagem)

        } else { placar.puladas.append("T25 downloads") }

        // TESTE 26: Endereço que o professor escreve na lousa.
        print("\n--- [26/26] Testes de Domínio: endereço para a turma digitar ---")
        let servidorDaLousa = FakeServer()
        let vmEndereco = MainViewModel(
            captureService: FakeCaptureService(), encoderService: FakeEncoder(),
            serverService: servidorDaLousa, advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity()
        )
        assertTest(vmEndereco.displayAddress == "192.168.1.10:8080", "O painel mostra o endereço sem o http://")
        assertTest(!vmEndereco.displayAddress.contains(".local"), "Sem sessão aberta e sem nome confirmado, o painel mostra o IP")
        assertTest(vmEndereco.serverURLString == "http://192.168.1.10:8080",
                   "O link copiado continua completo, para ser clicável quando colado")

        // Duas transmissões na mesma rede: o painel só mostra o nome que o mDNS confirmou.
        let nomeFalso = FakeHostname()
        let servidorNome = FakeServer()
        let vmNome = MainViewModel(
            captureService: FakeCaptureService(), encoderService: FakeEncoder(),
            serverService: servidorNome, advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity(),
            permission: FakePermission(concedida: true), hostnameService: nomeFalso
        )
        vmNome.startStream()
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(vmNome.isSessionOpen, "A sessão abre com o serviço de nome falso")
        assertTest(nomeFalso.ip == "192.168.1.10", "O nome é registrado apontando para o IP do servidor")
        assertTest(vmNome.displayAddress == "192.168.1.10:8080",
                   "Sessão aberta mas nome ainda não confirmado: o painel mostra o IP")
        nomeFalso.confirmar("aulacast-2.local")
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(vmNome.displayAddress == "aulacast-2.local:8080",
                   "Nome confirmado (o segundo professor da rede): o painel mostra aulacast-2.local")
        nomeFalso.confirmar(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(vmNome.displayAddress == "192.168.1.10:8080", "Nome perdido: o painel volta para o IP")

        // Trocou de Wi-Fi no meio da aula: o nome antigo aponta para o IP velho e sai do painel.
        nomeFalso.confirmar("aulacast.local")
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(vmNome.displayAddress == "aulacast.local:8080", "Nome confirmado antes da troca de rede")
        servidorNome.localIPAddress = "10.0.0.7"
        vmNome.updateServerURL()
        assertTest(vmNome.displayAddress == "10.0.0.7:8080",
                   "Trocou de IP: o painel mostra o IP novo, não um nome que apontaria para o antigo")
        assertTest(nomeFalso.ip == "10.0.0.7", "O nome é registrado de novo, apontando para o IP novo")

        // TESTE 27: Painel do professor.
        print("\n--- [27/27] Testes: painel do professor ---")
        let vmPainel = MainViewModel(
            captureService: FakeCaptureService(), encoderService: FakeEncoder(),
            serverService: FakeServer(), advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity()
        )
        vmPainel.didReceiveChatMessage(ChatMessage(sender: "Ana", text: "oi", isProf: false))
        vmPainel.didReceiveChatMessage(ChatMessage(sender: "Carlos", text: "dúvida", isProf: false))
        vmPainel.sendProfMessage(text: "respondendo")
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(vmPainel.studentMessagesReceived == 2,
                   "Só as mensagens dos alunos contam para o aviso de não lidas")

        // Mesmo com o histórico cheio (ele guarda só as últimas), a contagem segue subindo.
        for i in 0..<(ChatManagerService.maxMessages + 5) {
            vmPainel.didReceiveChatMessage(ChatMessage(sender: "Ana", text: "m\(i)", isProf: false))
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        assertTest(vmPainel.studentMessagesReceived == ChatManagerService.maxMessages + 7,
                   "Com o histórico no limite, as mensagens novas continuam contando como não lidas")

        assertTest(SourcePickerView<ScreenCaptureService>.colunas(paraLargura: 580) == 2, "Janela mínima: 2 colunas de fontes")
        assertTest(SourcePickerView<ScreenCaptureService>.colunas(paraLargura: 760) == 3, "Com o painel aberto: 3 colunas")
        assertTest(SourcePickerView<ScreenCaptureService>.colunas(paraLargura: 1120) == 5, "Painel fechado: as fontes ganham colunas")
        assertTest(SourcePickerView<ScreenCaptureService>.colunas(paraLargura: 3000) == 6, "Nunca passa de 6 colunas")

        if executarTudo {
        // TESTE 28: Mão levantada.
        // A turma pediu de volta. A mão é estado da conexão, o nome sai do IDENTIFY e a lista
        // do professor põe quem pediu primeiro no topo, como no Meet.
        print("\n--- [28/29] Testes: mão levantada ---")

        let salaDasMaos = ClientManagerService()
        let bia = ConnectedClient(name: "Aluno-0.31", ipAddress: "192.168.0.31")
        let caio = ConnectedClient(name: "Aluno-0.32", ipAddress: "192.168.0.32")
        let davi = ConnectedClient(name: "Aluno-0.33", ipAddress: "192.168.0.33")
        let semNome = ConnectedClient(name: "Aluno-0.34", ipAddress: "192.168.0.34")
        for c in [bia, caio, davi, semNome] { salaDasMaos.addOrUpdateClient(c) }
        salaDasMaos.identify(clientId: bia.id, name: "Bia")
        salaDasMaos.identify(clientId: caio.id, name: "Caio")
        salaDasMaos.identify(clientId: davi.id, name: "Davi")

        assertTest(salaDasMaos.handRaisedCount == 0, "Contador de mãos levantadas começa em zero")
        let t0 = Date()
        salaDasMaos.setHandRaised(clientId: davi.id, isRaised: true, at: t0)
        salaDasMaos.setHandRaised(clientId: bia.id, isRaised: true, at: t0.addingTimeInterval(5))
        assertTest(salaDasMaos.handRaisedCount == 2, "Duas mãos levantadas contam 2")
        assertTest(
            salaDasMaos.identifiedClientsInListOrder.map(\.name) == ["Davi", "Bia", "Caio"],
            "Quem levantou a mão vem primeiro, na ordem de quem levantou antes"
        )

        // A página repete a mensagem (ou o aluno clica duas vezes): não perde o lugar na fila.
        salaDasMaos.setHandRaised(clientId: davi.id, isRaised: true, at: t0.addingTimeInterval(10))
        assertTest(
            salaDasMaos.identifiedClientsInListOrder.first?.name == "Davi",
            "Levantar de novo com a mão já no alto mantém o lugar na fila"
        )

        salaDasMaos.setHandRaised(clientId: davi.id, isRaised: false)
        assertTest(salaDasMaos.handRaisedCount == 1, "Abaixar a mão desconta do contador")
        assertTest(
            salaDasMaos.identifiedClientsInListOrder.map(\.name) == ["Bia", "Caio", "Davi"],
            "Quem abaixa a mão volta ao lugar de chegada, depois das mãos levantadas"
        )

        // Levantar de novo depois de abaixar vai para o fim da fila, como no Meet.
        salaDasMaos.setHandRaised(clientId: davi.id, isRaised: true, at: t0.addingTimeInterval(20))
        assertTest(
            salaDasMaos.identifiedClientsInListOrder.map(\.name) == ["Bia", "Davi", "Caio"],
            "Quem levanta a mão de novo entra no fim da fila"
        )

        let totalAntesDaMaoFantasma = salaDasMaos.clients.count
        salaDasMaos.setHandRaised(clientId: "id-inexistente", isRaised: true)
        assertTest(salaDasMaos.clients.count == totalAntesDaMaoFantasma, "Mão levantada de conexão desconhecida é ignorada")
        salaDasMaos.setHandRaised(clientId: semNome.id, isRaised: true)
        assertTest(salaDasMaos.handRaisedCount == 2, "Conexão sem nome não entra na contagem de mãos")

        salaDasMaos.removeClient(id: bia.id)
        assertTest(salaDasMaos.handRaisedCount == 1, "A mão de quem saiu da aula não fica pendurada no contador")

        // Caminho completo no app do professor: servidor -> MainViewModel -> gerenciador,
        // e o "Abaixar a mão" do professor de volta ao servidor.
        let servidorDasMaos = FakeServer()
        let vmMaos = MainViewModel(
            captureService: FakeCaptureService(), encoderService: FakeEncoder(),
            serverService: servidorDasMaos, advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity()
        )
        assertTest(servidorDasMaos.handRaiseObserver === vmMaos, "O app do professor se registra para receber as mãos levantadas")
        let alunaDaMao = ConnectedClient(name: "Aluno-0.40", ipAddress: "192.168.0.40")
        vmMaos.didClientConnect(alunaDaMao)
        vmMaos.didIdentifyStudent(clientId: alunaDaMao.id, name: "Elisa")
        vmMaos.didToggleHandRaise(clientId: alunaDaMao.id, displayName: "Elisa", isRaised: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(vmMaos.clientManager.handRaisedCount == 1, "Mão levantada chega ao app do professor pelo caminho completo")
        assertTest(vmMaos.clientManager.clients.first?.isHandRaised == true, "A linha da aluna fica marcada com a mão levantada")

        vmMaos.lowerHand(clientId: alunaDaMao.id)
        assertTest(vmMaos.clientManager.handRaisedCount == 0, "Professor abaixa a mão e o contador zera na hora")
        assertTest(servidorDasMaos.maosAbaixadas == [alunaDaMao.id], "Abaixar a mão avisa o servidor só daquela aluna")
        vmMaos.lowerHand(clientId: alunaDaMao.id)
        assertTest(servidorDasMaos.maosAbaixadas.count == 1, "Abaixar a mão já abaixada não manda aviso repetido")

        vmMaos.didToggleHandRaise(clientId: alunaDaMao.id, displayName: "Elisa", isRaised: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        vmMaos.didToggleHandRaise(clientId: alunaDaMao.id, displayName: "Elisa", isRaised: false)
        try? await Task.sleep(nanoseconds: 150_000_000)
        assertTest(vmMaos.clientManager.handRaisedCount == 0, "A própria aluna abaixa a mão pelo caminho completo")
        assertTest(servidorDasMaos.maosAbaixadas.count == 1, "Quando a aluna abaixa sozinha, o servidor não recebe HAND_LOWERED")

        // Ponta a ponta pelo WebSocket real.
        final class ColetorDeMaos: HandRaiseObserverProtocol, ClientObserverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _conectados: [ConnectedClient] = []
            private var _maos: [(id: String, nome: String, levantada: Bool)] = []
            var conectados: [ConnectedClient] { trava.lock(); defer { trava.unlock() }; return _conectados }
            var maos: [(id: String, nome: String, levantada: Bool)] { trava.lock(); defer { trava.unlock() }; return _maos }
            func didToggleHandRaise(clientId: String, displayName: String, isRaised: Bool) {
                trava.lock(); _maos.append((clientId, displayName, isRaised)); trava.unlock()
            }
            func didClientConnect(_ client: ConnectedClient) {
                trava.lock(); _conectados.append(client); trava.unlock()
            }
            func didClientDisconnect(clientId: String) {}
        }

        /// Lê até achar a mensagem do tipo pedido e a devolve já decodificada, junto com os
        /// tipos que vieram antes dela (para provar que algo *não* foi enviado).
        func receberMensagem(
            _ socket: URLSessionWebSocketTask, tipo: String, tentativas: Int = 8
        ) async -> (mensagem: [String: Any]?, antes: [String]) {
            var antes: [String] = []
            for _ in 0..<tentativas {
                guard case .string(let texto)? = try? await socket.receive(),
                      let dados = texto.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
                      let recebido = json["type"] as? String else { return (nil, antes) }
                if recebido == tipo { return (json, antes) }
                antes.append(recebido)
            }
            return (nil, antes)
        }

        let coletorDeMaos = ColetorDeMaos()
        let servidorMaoReal = NetworkListenerService(port: 8120, webAssetsPath: FileManager.default.temporaryDirectory)
        servidorMaoReal.handRaiseObserver = coletorDeMaos
        servidorMaoReal.clientObserver = coletorDeMaos
        do {
            try servidorMaoReal.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let socketMao = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8120/ws")!)
            socketMao.resume()
            _ = await receberMensagem(socketMao, tipo: "CONNECTED")

            // Antes do IDENTIFY: ignorada, sem ACK e sem derrubar.
            try? await socketMao.send(.string("{\"type\":\"RAISE_HAND\",\"payload\":{\"active\":true}}"))
            try? await socketMao.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Fábio Lima\"}}"))
            let aceito = await receberMensagem(socketMao, tipo: "IDENTIFY_ACCEPTED")
            try? await Task.sleep(nanoseconds: 200_000_000)
            assertTest(aceito.mensagem != nil, "Mão levantada antes do IDENTIFY não derruba a conexão")
            assertTest(!aceito.antes.contains("RAISE_HAND_ACK"), "Mão levantada antes do IDENTIFY não recebe confirmação")
            assertTest(coletorDeMaos.maos.isEmpty, "Mão levantada antes do IDENTIFY não chega ao professor")

            // Identificado: o nome vem do IDENTIFY, não de um campo que o navegador inventar.
            try? await socketMao.send(.string(
                "{\"type\":\"RAISE_HAND\",\"payload\":{\"active\":true,\"name\":\"Outra Pessoa\",\"studentName\":\"Professor\"}}"
            ))
            let ackLevantada = await receberMensagem(socketMao, tipo: "RAISE_HAND_ACK")
            try? await Task.sleep(nanoseconds: 200_000_000)
            assertTest(
                (ackLevantada.mensagem?["payload"] as? [String: Any])?["active"] as? Bool == true,
                "Servidor confirma a mão levantada com RAISE_HAND_ACK active=true"
            )
            assertTest(coletorDeMaos.maos.count == 1 && coletorDeMaos.maos.first?.levantada == true,
                       "Mão levantada trafega pelo WebSocket real")
            assertTest(coletorDeMaos.maos.first?.nome == "Fábio Lima",
                       "A mão leva o nome aceito no IDENTIFY, não o que vem na mensagem")
            assertTest(coletorDeMaos.maos.first?.id == coletorDeMaos.conectados.first?.id,
                       "A mão é da mesma conexão (não um registro novo)")

            try? await socketMao.send(.string("{\"type\":\"RAISE_HAND\",\"payload\":{\"active\":false}}"))
            let ackAbaixada = await receberMensagem(socketMao, tipo: "RAISE_HAND_ACK")
            try? await Task.sleep(nanoseconds: 200_000_000)
            assertTest(
                (ackAbaixada.mensagem?["payload"] as? [String: Any])?["active"] as? Bool == false,
                "O aluno abaixa a própria mão e recebe RAISE_HAND_ACK active=false"
            )
            assertTest(coletorDeMaos.maos.last?.levantada == false, "A mão abaixada pelo aluno chega ao professor")

            // Sem o campo `active` não há o que fazer: ignora sem derrubar.
            try? await socketMao.send(.string("{\"type\":\"RAISE_HAND\"}"))
            try? await Task.sleep(nanoseconds: 200_000_000)
            assertTest(coletorDeMaos.maos.count == 2, "RAISE_HAND sem o campo active é ignorado")

            // O professor abaixa a mão: só aquele aluno recebe HAND_LOWERED.
            if let idDoAluno = coletorDeMaos.conectados.first?.id {
                servidorMaoReal.lowerHand(clientId: idDoAluno)
                let abaixada = await receberMensagem(socketMao, tipo: "HAND_LOWERED")
                assertTest(abaixada.mensagem != nil, "Professor abaixa a mão e o aluno recebe HAND_LOWERED")
                assertTest(abaixada.antes.isEmpty, "HAND_LOWERED chega sozinho, sem mensagens a mais")
            } else {
                assertTest(false, "Professor abaixa a mão e o aluno recebe HAND_LOWERED")
            }
            servidorMaoReal.lowerHand(clientId: "id-inexistente")
            try? await socketMao.send(.string("{\"type\":\"PING\"}"))
            let pong = await receberMensagem(socketMao, tipo: "PONG")
            assertTest(pong.mensagem != nil && pong.antes.isEmpty,
                       "Abaixar a mão de conexão desconhecida não manda nada a ninguém")

            socketMao.cancel(with: .goingAway, reason: nil)
            servidorMaoReal.stop()
        } catch {
            assertTest(false, "Falha no teste E2E da mão levantada: \(error.localizedDescription)")
        }

        // TESTE 29: Mensagem fixada no topo do chat da turma.
        print("\n--- [29/29] Testes: mensagem fixada ---")

        let chatDaFixada = ChatManagerService()
        chatDaFixada.sendProfMessage(text: "Portal do Aluno: https://portal.exemplo.edu.br")
        chatDaFixada.addMessage(ChatMessage(sender: "Gabi", text: "posso fixar?", isProf: false))
        let doProfessor = chatDaFixada.messages[0]
        let daAluna = chatDaFixada.messages[1]
        assertTest(!chatDaFixada.pin(daAluna) && chatDaFixada.pinnedMessage == nil,
                   "Mensagem de aluno não pode ser fixada (é privada com o professor)")
        assertTest(chatDaFixada.pin(doProfessor) && chatDaFixada.pinnedMessage?.id == doProfessor.id,
                   "Mensagem do professor é fixada")
        assertTest(!chatDaFixada.pin(doProfessor), "Fixar de novo a mesma mensagem não conta como mudança")

        // A fixada sobrevive ao histórico descartar as mensagens antigas.
        for i in 0..<(ChatManagerService.maxMessages + 1) {
            chatDaFixada.addMessage(ChatMessage(sender: "Gabi", text: "m\(i)", isProf: false))
        }
        assertTest(chatDaFixada.pinnedMessage?.id == doProfessor.id,
                   "A fixada continua de pé quando o histórico descarta as mensagens antigas")

        let servidorDaFixada = FakeServer()
        let vmFixada = MainViewModel(
            captureService: FakeCaptureService(), encoderService: FakeEncoder(),
            serverService: servidorDaFixada, advertiserService: FakeAdvertiser(), systemActivity: FakeSystemActivity()
        )
        vmFixada.sendProfMessage(text: "Leiam o capítulo 3")
        vmFixada.sendProfMessage(text: "Portal do Aluno: https://portal.exemplo.edu.br")
        let primeira = vmFixada.chatManager.messages[0]
        let segunda = vmFixada.chatManager.messages[1]

        vmFixada.pinMessage(primeira)
        assertTest(vmFixada.chatManager.pinnedMessage?.id == primeira.id, "Professor fixa uma mensagem dele")
        assertTest(servidorDaFixada.fixacoes == ["Leiam o capítulo 3"], "Fixar manda o texto para a turma")

        vmFixada.pinMessage(segunda)
        assertTest(vmFixada.chatManager.pinnedMessage?.id == segunda.id, "Fixar outra substitui a fixada (uma por vez)")
        assertTest(servidorDaFixada.fixacoes.last == "Portal do Aluno: https://portal.exemplo.edu.br",
                   "A substituta vai para a turma")
        vmFixada.pinMessage(segunda)
        assertTest(servidorDaFixada.fixacoes.count == 2, "Fixar a que já está fixada não reenvia")

        vmFixada.didReceiveChatMessage(ChatMessage(sender: "Hugo", text: "fixa a minha", isProf: false))
        try? await Task.sleep(nanoseconds: 150_000_000)
        if let doAluno = vmFixada.chatManager.messages.last, !doAluno.isProf {
            vmFixada.pinMessage(doAluno)
        }
        assertTest(vmFixada.chatManager.pinnedMessage?.id == segunda.id && servidorDaFixada.fixacoes.count == 2,
                   "Mensagem de aluno não chega a ser fixada nem enviada à turma")

        vmFixada.unpinMessage()
        assertTest(vmFixada.chatManager.pinnedMessage == nil, "Professor desafixa")
        assertTest(servidorDaFixada.fixacoes.count == 3 && servidorDaFixada.fixacoes.last! == nil,
                   "Desafixar avisa a turma com texto nulo")
        vmFixada.unpinMessage()
        assertTest(servidorDaFixada.fixacoes.count == 3, "Desafixar sem nada fixado não manda aviso")

        // Ponta a ponta: formato exato das mensagens, com aspas e quebra de linha no texto.
        func boasVindasEm(_ porta: Int) async -> [String: Any]? {
            let s = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(porta)/ws")!)
            s.resume()
            defer { s.cancel(with: .goingAway, reason: nil) }
            return (await receberMensagem(s, tipo: "CONNECTED")).mensagem?["payload"] as? [String: Any]
        }

        let servidorFixadaReal = NetworkListenerService(port: 8121, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorFixadaReal.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let semFixada = await boasVindasEm(8121)
            assertTest(semFixada != nil && semFixada?["pinned"] == nil, "Sem fixada, o CONNECTED não traz o campo pinned")

            let socketFixada = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8121/ws")!)
            socketFixada.resume()
            _ = await receberMensagem(socketFixada, tipo: "CONNECTED")

            let textoCapcioso = "Portal do Aluno: \"https://portal.exemplo.edu.br/aluno?a=1&b=2\"\nSenha: sua matrícula \\o/ 🎓"
            servidorFixadaReal.updatePinnedMessage(textoCapcioso)
            let fixou = await receberMensagem(socketFixada, tipo: "CHAT_PINNED")
            assertTest(
                (fixou.mensagem?["payload"] as? [String: Any])?["text"] as? String == textoCapcioso,
                "CHAT_PINNED leva o texto intacto, com aspas, quebra de linha e barra invertida"
            )
            let comFixada = await boasVindasEm(8121)
            assertTest(comFixada?["pinned"] as? String == textoCapcioso, "Quem entra depois recebe a fixada no CONNECTED")
            assertTest(comFixada?["chatEnabled"] as? Bool == true && comFixada?["files"] != nil,
                       "A fixada no CONNECTED não tira os outros campos das boas-vindas")

            servidorFixadaReal.updatePinnedMessage("Prova na sexta")
            let substituiu = await receberMensagem(socketFixada, tipo: "CHAT_PINNED")
            assertTest((substituiu.mensagem?["payload"] as? [String: Any])?["text"] as? String == "Prova na sexta",
                       "Fixar outra manda a substituta a quem está conectado")
            assertTest((await boasVindasEm(8121))?["pinned"] as? String == "Prova na sexta",
                       "O CONNECTED passa a trazer a substituta")

            servidorFixadaReal.updatePinnedMessage(nil)
            let desafixou = await receberMensagem(socketFixada, tipo: "CHAT_PINNED")
            let payloadDesafixou = desafixou.mensagem?["payload"] as? [String: Any]
            assertTest(payloadDesafixou?.keys.contains("text") == true && payloadDesafixou?["text"] is NSNull,
                       "Desafixar manda CHAT_PINNED com text null")
            let depoisDeDesafixar = await boasVindasEm(8121)
            assertTest(depoisDeDesafixar != nil && depoisDeDesafixar?["pinned"] == nil,
                       "Depois de desafixar, o CONNECTED volta a vir sem o campo pinned")

            socketFixada.cancel(with: .goingAway, reason: nil)
            servidorFixadaReal.stop()
        } catch {
            assertTest(false, "Falha no teste E2E da mensagem fixada: \(error.localizedDescription)")
        }

        // TESTE 30: Chat visível entre alunos — toggle independente, desligado por padrão.
        // Desligado (comportamento atual): mensagem de aluno só chega ao próprio autor e ao
        // professor. Ligado: chega a toda a turma, sem duplicar o eco de quem escreveu
        // (broadcastChatMessage já inclui o remetente).
        print("\n--- [30/31] Testes E2E: chat visível entre alunos ---")

        let coletorChatTurma = ColetorDeChat()
        let servidorChatTurma = NetworkListenerService(port: 8122, webAssetsPath: FileManager.default.temporaryDirectory)
        servidorChatTurma.chatObserver = coletorChatTurma

        do {
            try servidorChatTurma.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            assertTest(servidorChatTurma.isStudentChatVisibleToClass == false,
                       "Chat visível entre alunos começa desligado")

            let alunoX = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8122/ws")!)
            let alunoY = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8122/ws")!)
            let alunoZ = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8122/ws")!)
            alunoX.resume()
            alunoY.resume()
            alunoZ.resume()

            await descartarBoasVindas(alunoX)
            await descartarBoasVindas(alunoY)
            await descartarBoasVindas(alunoZ)

            /// Guarda a primeira mensagem que chegar numa conexão (mesmo desenho do teste de
            /// privacidade do chat, TESTE 11 — cada `receive` só pode ter uma chamada pendente).
            final class CaixaDeEscuta: @unchecked Sendable {
                private let trava = NSLock()
                private var _texto: String?
                var texto: String? { trava.lock(); defer { trava.unlock() }; return _texto }
                func guardar(_ t: String) { trava.lock(); if _texto == nil { _texto = t }; trava.unlock() }
            }

            // --- Desligado (padrão): regressão explícita do comportamento já existente. ---
            let escutaYDesligado = CaixaDeEscuta()
            let escutaZDesligado = CaixaDeEscuta()
            Task { if case .string(let t)? = try? await alunoY.receive() { escutaYDesligado.guardar(t) } }
            Task { if case .string(let t)? = try? await alunoZ.receive() { escutaZDesligado.guardar(t) } }

            try? await alunoX.send(.string(
                "{\"type\":\"CHAT_SEND\",\"payload\":{\"sender\":\"Xana\",\"text\":\"so o prof ve isso\"}}"
            ))
            try? await Task.sleep(nanoseconds: 400_000_000)

            assertTest(coletorChatTurma.recebidas.count == 1, "Toggle desligado: mensagem chega ao professor")

            var ecoParaAutorDesligado = false
            if case .string(let texto)? = try? await alunoX.receive(), texto.contains("so o prof ve isso") {
                ecoParaAutorDesligado = true
            }
            assertTest(ecoParaAutorDesligado, "Toggle desligado: o autor recebe a própria mensagem de volta")

            // Tempo de rede real antes de concluir que nada chegou aos colegas.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            assertTest(
                escutaYDesligado.texto == nil && escutaZDesligado.texto == nil,
                "Toggle desligado: mensagem de aluno NÃO chega aos colegas (regressão)"
            )

            // Os `receive()` de Y e Z acima ficam pendentes para sempre: é a prova de que
            // nada chegou a eles, e sem cancelar a conexão não há como desarmá-los. Reaproveitar
            // esses mesmos sockets na fase seguinte empilharia um segundo `receive()` concorrente
            // em cima do que já está pendente — foi exatamente isso que travou a suíte do TESTE
            // 11 (ver comentário lá). A fase ligada usa conexões novas, sem escuta pendente.
            alunoX.cancel(with: .goingAway, reason: nil)
            alunoY.cancel(with: .goingAway, reason: nil)
            alunoZ.cancel(with: .goingAway, reason: nil)

            // --- Ligado: mensagem do aluno chega a toda a turma, sem duplicar o próprio eco. ---
            servidorChatTurma.isStudentChatVisibleToClass = true

            let autora = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8122/ws")!)
            let colegaQ = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8122/ws")!)
            let colegaR = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8122/ws")!)
            autora.resume()
            colegaQ.resume()
            colegaR.resume()

            await descartarBoasVindas(autora)
            await descartarBoasVindas(colegaQ)
            await descartarBoasVindas(colegaR)

            let escutaQ = CaixaDeEscuta()
            let escutaR = CaixaDeEscuta()
            Task { if case .string(let t)? = try? await colegaQ.receive() { escutaQ.guardar(t) } }
            Task { if case .string(let t)? = try? await colegaR.receive() { escutaR.guardar(t) } }

            try? await autora.send(.string(
                "{\"type\":\"CHAT_SEND\",\"payload\":{\"sender\":\"Yara\",\"text\":\"agora todo mundo ve\"}}"
            ))
            try? await Task.sleep(nanoseconds: 800_000_000)

            assertTest(coletorChatTurma.recebidas.count == 2, "Toggle ligado: mensagem também chega ao professor")
            assertTest(
                escutaQ.texto?.contains("agora todo mundo ve") == true,
                "Toggle ligado: chega a um colega conectado"
            )
            assertTest(
                escutaR.texto?.contains("agora todo mundo ve") == true,
                "Toggle ligado: chega a outro colega conectado"
            )

            // A própria autora recebe de volta pelo broadcast (que já inclui quem escreveu).
            // Esta é a primeira (e única, até aqui) chamada de `receive()` no socket dela,
            // então não corre o mesmo risco de escuta duplicada de Y e Z acima.
            var ecoParaAutoraLigado = false
            if case .string(let texto)? = try? await autora.receive(), texto.contains("agora todo mundo ve") {
                ecoParaAutoraLigado = true
            }
            assertTest(ecoParaAutoraLigado, "Toggle ligado: a autora também recebe a própria mensagem")

            // Só broadcastChatMessage foi chamado (não também sendChatMessage): a próxima
            // coisa que a autora recebe é outra mensagem, não um segundo eco da mesma —
            // prova de que a implementação não soma os dois caminhos e duplica o envio. Essa
            // segunda chamada em `autora` é sequencial (a primeira já terminou), não concorrente.
            try? await colegaR.send(.string(
                "{\"type\":\"CHAT_SEND\",\"payload\":{\"sender\":\"Zeca\",\"text\":\"prova que nao duplicou\"}}"
            ))
            var proximaParaAutora: String?
            if case .string(let texto)? = try? await autora.receive() { proximaParaAutora = texto }
            assertTest(
                proximaParaAutora?.contains("prova que nao duplicou") == true,
                "Toggle ligado: sem duplicar — a autora não recebe um segundo eco da própria mensagem"
            )

            autora.cancel(with: .goingAway, reason: nil)
            colegaQ.cancel(with: .goingAway, reason: nil)
            colegaR.cancel(with: .goingAway, reason: nil)
            servidorChatTurma.stop()
        } catch {
            assertTest(false, "Falha no teste E2E do chat visível entre alunos: \(error.localizedDescription)")
        }

        } else { placar.puladas.append("T28-T30 mão/fixada/chat turma") }

        // TESTE 31: Nome mDNS por tentativa (sem tocar a rede).
        print("\n--- [31/33] Testes de Domínio: nome mDNS por tentativa ---")
        assertTest(MDNSHostnameService.hostname(attempt: 1) == "aulacast.local.", "Tentativa 1 usa o nome sem número")
        assertTest(MDNSHostnameService.hostname(attempt: 2) == "aulacast-2.local.", "Tentativa 2 vira aulacast-2")
        assertTest(MDNSHostnameService.hostname(attempt: 7) == "aulacast-7.local.", "Tentativa 7 vira aulacast-7")
        assertTest(MDNSHostnameService.hostname(attempt: 0) == "aulacast.local.", "Tentativa 0 se comporta como a 1")
        assertTest(MDNSHostnameService.hostname(attempt: -3) == "aulacast.local.", "Tentativa negativa se comporta como a 1")
        assertTest(MDNSHostnameService.maxAttempts > 1, "Há mais de uma tentativa de nome antes de desistir")
        assertTest(
            MDNSHostnameService.hostname(attempt: MDNSHostnameService.maxAttempts)
                == "aulacast-\(MDNSHostnameService.maxAttempts).local.",
            "A última tentativa permitida ainda gera um nome numerado"
        )
        // Erros do dnssd: 0 = sem erro, -65548 = conflito de nome, -65537 = desconhecido.
        assertTest(MDNSHostnameService.proximoPasso(erro: 0, tentativa: 1) == .confirmar,
                   "Sem erro: o nome é confirmado")
        assertTest(MDNSHostnameService.proximoPasso(erro: -65548, tentativa: 1) == .tentarCom(tentativa: 2),
                   "Conflito no primeiro nome: tenta o aulacast-2")
        assertTest(MDNSHostnameService.proximoPasso(erro: -65548, tentativa: 2) == .tentarCom(tentativa: 3),
                   "Conflito no segundo nome: tenta o aulacast-3")
        assertTest(MDNSHostnameService.proximoPasso(erro: -65548, tentativa: MDNSHostnameService.maxAttempts) == .desistir,
                   "Conflito na última tentativa: desiste e deixa só o IP")
        assertTest(MDNSHostnameService.proximoPasso(erro: -65537, tentativa: 1) == .falhar,
                   "Outro erro qualquer: falha, sem nome")

        // TESTE 32: Taxas entre duas fotografias dos contadores.
        print("\n--- [32/33] Testes de Domínio: StreamRates.entre ---")
        let alunoA: UInt64 = 1
        let alunoB: UInt64 = 2
        let alunoC: UInt64 = 3

        var antesT = StreamSnapshot()
        antesT.quadrosPublicados = 100
        antesT.bytesEnviados = 5_000_000
        antesT.quadrosPorAluno = [alunoA: 10, alunoB: 20]
        var depoisT = StreamSnapshot()
        depoisT.quadrosPublicados = 160
        depoisT.bytesEnviados = 6_250_000
        depoisT.quadrosPorAluno = [alunoA: 40, alunoB: 30, alunoC: 99]

        let taxas = StreamRates.entre(antesT, e: depoisT, segundos: 2)
        assertTest(taxas?.alunos == 2, "Aluno só na fotografia de depois fica de fora da contagem")
        assertTest(taxas?.fpsMedioPorAluno == 10, "fps médio por aluno: (15 + 5) / 2 = 10")
        assertTest(taxas?.fpsMinimoPorAluno == 5, "fps mínimo por aluno é o do mais lento")
        assertTest(taxas?.fpsDaTela == 30, "fps da tela sai da diferença de quadros publicados")
        assertTest(taxas?.megabitsPorSegundo == 5, "1_250_000 bytes em 2 s = 5 Mbps")

        var antesComSaida = antesT
        antesComSaida.quadrosPorAluno[alunoC] = 1
        var depoisSemB = depoisT
        depoisSemB.quadrosPorAluno.removeValue(forKey: alunoB)
        depoisSemB.quadrosPorAluno.removeValue(forKey: alunoC)
        let taxasSaida = StreamRates.entre(antesComSaida, e: depoisSemB, segundos: 2)
        assertTest(taxasSaida?.alunos == 1 && taxasSaida?.fpsMedioPorAluno == 15,
                   "Aluno só na fotografia de antes (saiu) fica de fora")

        var umSegundoDepois = StreamSnapshot()
        umSegundoDepois.bytesEnviados = 1_250_000
        let taxaMbps = StreamRates.entre(StreamSnapshot(), e: umSegundoDepois, segundos: 1)
        assertTest(taxaMbps?.megabitsPorSegundo == 10, "1_250_000 bytes em 1 s = 10 Mbps")

        let semAlunos = StreamRates.entre(StreamSnapshot(), e: StreamSnapshot(), segundos: 1)
        assertTest(semAlunos?.alunos == 0 && semAlunos?.fpsMedioPorAluno == 0 && semAlunos?.fpsMinimoPorAluno == 0,
                   "Sem alunos, fps médio e mínimo são 0 (e não infinito)")
        assertTest(StreamRates.entre(antesT, e: depoisT, segundos: 0) == nil, "Intervalo de 0 s é inválido")
        assertTest(StreamRates.entre(antesT, e: depoisT, segundos: -1) == nil, "Intervalo negativo é inválido")

        var recuou = StreamSnapshot()
        recuou.quadrosPublicados = 5
        recuou.bytesEnviados = 5
        recuou.quadrosPorAluno = [alunoA: 1]
        var avancado = StreamSnapshot()
        avancado.quadrosPublicados = 10
        avancado.bytesEnviados = 10
        avancado.quadrosPorAluno = [alunoA: 2]
        let taxasRecuo = StreamRates.entre(avancado, e: recuou, segundos: 1)
        assertTest(taxasRecuo?.alunos == 0, "Aluno cujo contador recuou fica de fora, em vez de virar bilhões de fps")
        assertTest(taxasRecuo?.fpsDaTela == 0 && taxasRecuo?.megabitsPorSegundo == 0,
                   "Contadores de tela e bytes que recuaram contam como zero, não como uma volta de 2^64")

        if executarTudo {
        // TESTE 33: Contadores reais do vídeo, com o servidor de verdade.
        print("\n--- [33/33] Testes de Rede: contadores de quadros por aluno ---")
        let servidorContadores = NetworkListenerService(
            port: 8130,
            webAssetsPath: FileManager.default.temporaryDirectory
        )
        func abrirVideoBruto(_ porta: UInt16) -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var destino = sockaddr_in()
            destino.sin_family = sa_family_t(AF_INET)
            destino.sin_port = in_port_t(porta.bigEndian)
            destino.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &destino) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let pedido = "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n"
            _ = pedido.withCString { send(fd, $0, strlen($0), 0) }
            return fd
        }
        do {
            try servidorContadores.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let inicial = servidorContadores.streamSnapshot()
            assertTest(inicial.quadrosPublicados == 0 && inicial.bytesEnviados == 0 && inicial.quadrosPorAluno.isEmpty,
                       "Servidor novo começa com os contadores zerados")

            let fd1 = abrirVideoBruto(8130)
            let fd2 = abrirVideoBruto(8130)
            try? await Task.sleep(nanoseconds: 500_000_000)
            assertTest(servidorContadores.streamSnapshot().quadrosPorAluno.count == 2,
                       "Dois alunos conectados aparecem nos contadores")

            let totalQuadros = 5
            for i in 0..<totalQuadros {
                servidorContadores.broadcastFrame(Data(repeating: UInt8(i + 1), count: 2048 + i))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)

            let aposQuadros = servidorContadores.streamSnapshot()
            assertTest(aposQuadros.quadrosPublicados == UInt64(totalQuadros),
                       "Quadros publicados = \(totalQuadros) (veio \(aposQuadros.quadrosPublicados))")
            assertTest(aposQuadros.bytesEnviados > 0, "Bytes enviados contados (\(aposQuadros.bytesEnviados))")
            assertTest(aposQuadros.quadrosPorAluno.count == 2, "Os dois alunos seguem na lista")
            assertTest(
                aposQuadros.quadrosPorAluno.values.allSatisfy { $0 >= 1 && $0 <= UInt64(totalQuadros) },
                "Cada aluno recebeu entre 1 e \(totalQuadros) quadros (veio \(Array(aposQuadros.quadrosPorAluno.values)))"
            )

            // Passou bem mais que os 150 ms da repetição do Safari: a repetição já aconteceu.
            let antesDaRepeticao = aposQuadros.quadrosPorAluno
            try? await Task.sleep(nanoseconds: 800_000_000)
            let depoisDaRepeticao = servidorContadores.streamSnapshot()
            assertTest(depoisDaRepeticao.quadrosPorAluno == antesDaRepeticao,
                       "A repetição do último quadro não conta como quadro novo do aluno")
            assertTest(depoisDaRepeticao.quadrosPublicados == UInt64(totalQuadros),
                       "A repetição também não conta como quadro publicado")

            // Um aluno sai: lê o que chegou antes de fechar, para sair com FIN e não RST.
            var lixo = [UInt8](repeating: 0, count: 65536)
            _ = recv(fd1, &lixo, lixo.count, MSG_DONTWAIT)
            close(fd1)
            var restantes = servidorContadores.streamSnapshot().quadrosPorAluno.count
            for _ in 0..<10 where restantes > 1 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                restantes = servidorContadores.streamSnapshot().quadrosPorAluno.count
            }
            assertTest(restantes == 1, "Aluno que sai deixa os contadores (sobraram: \(restantes))")

            close(fd2)
            servidorContadores.stop()
        } catch {
            assertTest(false, "Falha no teste dos contadores de vídeo: \(error.localizedDescription)")
        }

        // Um único quadro, depois de parar a tela: a repetição não pode somar um segundo.
        let servidorUnico = NetworkListenerService(port: 8131, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorUnico.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let fd = abrirVideoBruto(8131)
            try? await Task.sleep(nanoseconds: 500_000_000)
            servidorUnico.broadcastFrame(Data(repeating: 0x42, count: 2048))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let unico = servidorUnico.streamSnapshot()
            assertTest(unico.quadrosPorAluno.count == 1 && unico.quadrosPorAluno.values.first == 1,
                       "Um quadro publicado e tela parada: o aluno conta exatamente 1 (veio \(Array(unico.quadrosPorAluno.values)))")
            close(fd)
            servidorUnico.stop()
        } catch {
            assertTest(false, "Falha no teste do quadro único: \(error.localizedDescription)")
        }

        // TESTE 34: pipeline H.264 + fMP4 (H264FrameEncoder, FMP4Packager, MP4StreamerService).
        // Ver PLANO-COMPRESSAO-DE-VIDEO.md na raiz do repositório para o porquê de cada peça.
        print("\n--- [34/35] Testes: codificação H.264 e empacotamento fMP4 ---")

        final class ColetorDeAccessUnits: H264AccessUnitReceiverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _unidades: [H264AccessUnit] = []
            var unidades: [H264AccessUnit] { trava.lock(); defer { trava.unlock() }; return _unidades }
            func didReceiveAccessUnit(_ unit: H264AccessUnit) { trava.lock(); _unidades.append(unit); trava.unlock() }
        }

        // Tempo de parede de verdade, não um relógio sintético de 30fps: o encoder está em
        // modo `RealTime`, e alimentá-lo com PTS que não batem com o intervalo real entre
        // chamadas (o teste espera de propósito entre cada quadro) faz o controle de taxa
        // interno tratar o quadro como fora de ordem/atrasado — e descartá-lo, sem erro.
        let inicioDoTesteH264 = CFAbsoluteTimeGetCurrent()
        func criarAmostraH264(indice: Int) -> CMSampleBuffer? {
            let tempoSegundos = CFAbsoluteTimeGetCurrent() - inicioDoTesteH264
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { return nil }
            // Conteúdo tem que MUDAR de um quadro para o outro: um encoder com predição entre
            // quadros pode legitimamente não gerar saída nenhuma para um quadro idêntico ao
            // anterior (é exatamente o ganho de banda que justifica trocar o MJPEG por isto —
            // ver PLANO-COMPRESSAO-DE-VIDEO.md) — quadros em branco repetidos testariam esse
            // comportamento, não a entrega de "vários quadros".
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                memset(base, Int32((indice * 40 + 10) % 256), bytesPerRow * CVPixelBufferGetHeight(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            var formato: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &formato)
            guard let formato else { return nil }
            var tempo = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(seconds: tempoSegundos, preferredTimescale: 600),
                decodeTimeStamp: .invalid
            )
            var amostra: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: formato,
                                                     sampleTiming: &tempo, sampleBufferOut: &amostra)
            return amostra
        }

        let coletorAU = ColetorDeAccessUnits()
        let encoderH264 = H264FrameEncoder()
        encoderH264.h264OutputReceiver = coletorAU

        // 15 quadros, não 5: o encoder de baixa latência segura um pequeno buffer de partida
        // (poucos quadros sem devolver nada) antes de entrar em regime — um teste curto demais
        // mediria só esse aquecimento, não a entrega em regime permanente.
        // Aquecimento: o encoder de hardware pode levar mais de um segundo para o primeiro uso
        // do processo (logo depois de recompilar) e descarta quadros enquanto isso. Espera-se o
        // primeiro quadro entregue, até ~6 s, e só então se mede a entrega em regime.
        var indiceAquecimento = 100
        while coletorAU.unidades.isEmpty && indiceAquecimento < 140 {
            if let amostra = criarAmostraH264(indice: indiceAquecimento) {
                encoderH264.encode(sampleBuffer: amostra)
            }
            indiceAquecimento += 1
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let jaEntregues = coletorAU.unidades.count

        for indice in 0..<15 {
            if let amostra = criarAmostraH264(indice: indice) {
                encoderH264.encode(sampleBuffer: amostra)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let unidades = coletorAU.unidades
        let emRegime = unidades.count - jaEntregues
        assertTest(emRegime >= 8, "O encoder H.264 entrega vários quadros em regime (recebidos: \(emRegime) de 15)")
        assertTest(unidades.first?.isKeyFrame == true, "O primeiro quadro do encoder H.264 é sempre quadro-chave")

        func contemNAL(_ dados: Data, tipo: UInt8) -> Bool {
            let startCode = Data([0, 0, 0, 1])
            var indice = dados.startIndex
            while let intervalo = dados.range(of: startCode, in: indice..<dados.endIndex) {
                if intervalo.upperBound < dados.endIndex, dados[intervalo.upperBound] & 0x1F == tipo { return true }
                indice = intervalo.upperBound
            }
            return false
        }
        if let primeira = unidades.first {
            assertTest(contemNAL(primeira.data, tipo: 7), "O quadro-chave inclui o SPS em Annex-B")
            assertTest(contemNAL(primeira.data, tipo: 8), "O quadro-chave inclui o PPS em Annex-B")
        }

        // O empacotador fMP4 encadeado no mesmo encoder: init segment primeiro, fragmentos depois.
        final class ColetorDeFragmentos: FMP4FragmentReceiverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _fragmentos: [(data: Data, isInitSegment: Bool, isKeyFrame: Bool)] = []
            var fragmentos: [(data: Data, isInitSegment: Bool, isKeyFrame: Bool)] {
                trava.lock(); defer { trava.unlock() }; return _fragmentos
            }
            func didReceiveFragment(_ data: Data, isInitSegment: Bool, isKeyFrame: Bool) {
                trava.lock(); _fragmentos.append((data, isInitSegment, isKeyFrame)); trava.unlock()
            }
        }

        let coletorFrag = ColetorDeFragmentos()
        let empacotador = FMP4Packager()
        empacotador.outputReceiver = coletorFrag
        for unidade in unidades { empacotador.didReceiveAccessUnit(unidade) }

        let fragmentos = coletorFrag.fragmentos
        assertTest(fragmentos.first?.isInitSegment == true, "O primeiro fragmento entregue é o init segment")
        if let initSegment = fragmentos.first?.data, initSegment.count > 8 {
            assertTest(initSegment.subdata(in: 4..<8) == Data("ftyp".utf8),
                       "O init segment começa com uma caixa ftyp válida")
            assertTest(initSegment.range(of: Data("moov".utf8)) != nil, "O init segment contém uma caixa moov")
        }
        let fragmentosDeQuadro = fragmentos.drop(while: { $0.isInitSegment })
        assertTest(fragmentosDeQuadro.count >= 1, "Pelo menos um fragmento moof+mdat foi entregue")
        if let primeiroFragmento = fragmentosDeQuadro.first?.data, primeiroFragmento.count > 8 {
            assertTest(primeiroFragmento.subdata(in: 4..<8) == Data("moof".utf8), "O fragmento começa com uma caixa moof")
            assertTest(primeiroFragmento.range(of: Data("mdat".utf8)) != nil, "O fragmento contém uma caixa mdat")
        }

        // A rota /stream.mp4 entrega o init segment e os fragmentos publicados, na ordem — mesmo
        // padrão de teste usado para /stream (ver TESTE 22).
        let servidorMP4 = NetworkListenerService(port: 8130, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorMP4.start()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var destino = sockaddr_in()
            destino.sin_family = sa_family_t(AF_INET)
            destino.sin_port = in_port_t(UInt16(8130).bigEndian)
            destino.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &destino) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var espera = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &espera, socklen_t(MemoryLayout<timeval>.size))
            _ = "GET /stream.mp4 HTTP/1.1\r\nHost: x\r\n\r\n".withCString { send(fd, $0, strlen($0), 0) }
            try? await Task.sleep(nanoseconds: 200_000_000)

            let initSegmentDeTeste = Data("ftyp-fake-init".utf8)
            servidorMP4.broadcastVideoFragment(initSegmentDeTeste, isInitSegment: true, isKeyFrame: true)
            let fragmentoDeTeste = Data("moof-fake-fragment".utf8)
            servidorMP4.broadcastVideoFragment(fragmentoDeTeste, isInitSegment: false, isKeyFrame: true)
            try? await Task.sleep(nanoseconds: 500_000_000)

            var recebido = Data()
            var pedaco = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(fd, &pedaco, pedaco.count, MSG_DONTWAIT)
                if n <= 0 { break }
                recebido.append(contentsOf: pedaco[0..<n])
            }
            let texto = String(data: recebido, encoding: .isoLatin1) ?? ""
            assertTest(texto.contains("Content-Type: video/mp4"), "/stream.mp4 responde com Content-Type: video/mp4")
            assertTest(recebido.range(of: initSegmentDeTeste) != nil, "/stream.mp4 entrega o init segment publicado")
            assertTest(recebido.range(of: fragmentoDeTeste) != nil, "/stream.mp4 entrega o fragmento publicado")
            if let intervaloInit = recebido.range(of: initSegmentDeTeste),
               let intervaloFrag = recebido.range(of: fragmentoDeTeste) {
                assertTest(intervaloInit.lowerBound < intervaloFrag.lowerBound, "O init segment chega antes do fragmento")
            }

            close(fd)
            servidorMP4.stop()
        } catch {
            assertTest(false, "Falha no teste da rota /stream.mp4: \(error.localizedDescription)")
        }

        // Uma conexão nova chegando pede um quadro-chave ao encoder ativo, para o aluno não
        // ficar sem imagem até o próximo quadro-chave "de rotina".
        final class ContadorDePedidos: @unchecked Sendable {
            private let trava = NSLock()
            private var _pedidos = 0
            func pedir() { trava.lock(); _pedidos += 1; trava.unlock() }
            var pedidos: Int { trava.lock(); defer { trava.unlock() }; return _pedidos }
        }
        let servidorKeyFrame = NetworkListenerService(port: 8131, webAssetsPath: FileManager.default.temporaryDirectory)
        let contadorPedidos = ContadorDePedidos()
        servidorKeyFrame.onVideoViewerNeedsKeyFrame = { contadorPedidos.pedir() }
        do {
            try servidorKeyFrame.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let fd2 = socket(AF_INET, SOCK_STREAM, 0)
            var destino2 = sockaddr_in()
            destino2.sin_family = sa_family_t(AF_INET)
            destino2.sin_port = in_port_t(UInt16(8131).bigEndian)
            destino2.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &destino2) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd2, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            _ = "GET /stream.mp4 HTTP/1.1\r\nHost: x\r\n\r\n".withCString { send(fd2, $0, strlen($0), 0) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            assertTest(contadorPedidos.pedidos >= 1, "Conexão nova em /stream.mp4 pede quadro-chave ao encoder")
            close(fd2)
            servidorKeyFrame.stop()
        } catch {
            assertTest(false, "Falha no teste de pedido de quadro-chave: \(error.localizedDescription)")
        }

        // Pausa: nenhum fragmento novo sai para a turma, no mesmo portão que já protege o
        // MJPEG (ver TESTE 10, "prévia da transmissão").
        let servidorDaPausaMP4 = FakeServer()
        let vmPausaMP4 = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorDaPausaMP4,
            advertiserService: FakeAdvertiser()
        )
        let fragmentoDePausa = Data("fragmento-de-teste".utf8)
        vmPausaMP4.didReceiveFragment(fragmentoDePausa, isInitSegment: false, isKeyFrame: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(servidorDaPausaMP4.fragmentosEnviados.count == 1, "Sem pausa, o fragmento chega à turma")

        vmPausaMP4.togglePause()
        vmPausaMP4.didReceiveFragment(fragmentoDePausa, isInitSegment: false, isKeyFrame: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(
            servidorDaPausaMP4.fragmentosEnviados.count == 1,
            "Em pausa, nenhum fragmento novo de vídeo H.264 chega à turma"
        )
        vmPausaMP4.togglePause()

        // TESTE 35: correções da revisão do H.264 (duração, init, rota, rate limit, filas, métricas).
        print("\n--- [35/35] Testes: robustez do pipeline H.264/fMP4 (duração, init, cabeçalho, filas, métricas) ---")

        // Access units sintéticos: SPS/PPS/IDR ou P-slice em Annex-B (preenchimento 0x11 evita start code falso).
        func unidadeSintetica(chave: Bool, segundos: Double, sps: UInt8 = 0x1F) -> H264AccessUnit {
            var dados = Data()
            if chave {
                dados.append(contentsOf: [0, 0, 0, 1, 0x67, 0x42, 0x00, sps, 0x11, 0x11])
                dados.append(contentsOf: [0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80])
                dados.append(contentsOf: [0, 0, 0, 1, 0x65, 0x88] + [UInt8](repeating: 0x11, count: 64))
            } else {
                dados.append(contentsOf: [0, 0, 0, 1, 0x41, 0x9A] + [UInt8](repeating: 0x11, count: 32))
            }
            return H264AccessUnit(data: dados, presentationTime: CMTime(seconds: segundos, preferredTimescale: 600),
                                  isKeyFrame: chave, width: 1920, height: 1080)
        }
        func inteiroBE(_ d: Data, _ inicio: Int, _ bytes: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<bytes { v = (v << 8) | UInt64(d[d.startIndex + inicio + i]) }
            return v
        }
        func duracaoDoFragmento(_ d: Data) -> UInt64? {
            d.range(of: Data("trun".utf8)).map { inteiroBE(d, $0.upperBound - d.startIndex + 12, 4) }
        }
        func tfdtDoFragmento(_ d: Data) -> UInt64? {
            d.range(of: Data("tfdt".utf8)).map { inteiroBE(d, $0.upperBound - d.startIndex + 4, 8) }
        }

        // (1) duração depois de 30 s parado + (3) timeline contínua
        do {
            let coletor = ColetorDeFragmentos()
            let pacote = FMP4Packager()
            pacote.outputReceiver = coletor
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: true, segundos: 0))
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: false, segundos: 1.0 / 30))
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: false, segundos: 30.1))
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: false, segundos: 30.1 + 1.0 / 30))
            let midia = coletor.fragmentos.filter { !$0.isInitSegment }.map { $0.data }
            assertTest(midia.count == 4, "Empacotador: 4 fragmentos de mídia (veio \(midia.count))")
            if midia.count == 4 {
                let duracoes = midia.compactMap(duracaoDoFragmento)
                assertTest(duracoes.count == 4 && duracoes.allSatisfy { $0 >= 1 && $0 <= 6000 },
                           "Depois de 30 s de tela parada a duração do quadro é limitada a 2 períodos (veio \(duracoes))")
                let bases = midia.compactMap(tfdtDoFragmento)
                var continua = bases.count == 4
                for i in 1..<max(1, bases.count) where bases[i] != bases[i - 1] + duracoes[i - 1] { continua = false }
                assertTest(continua, "baseMediaDecodeTime avança pela mesma duração (linha do tempo contínua: \(bases))")
            }
        }

        // (4) init por SPS/PPS, reset(), duas sessões
        do {
            let coletor = ColetorDeFragmentos()
            let pacote = FMP4Packager()
            pacote.outputReceiver = coletor
            func inits() -> Int { coletor.fragmentos.filter { $0.isInitSegment }.count }
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: true, segundos: 0))
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: true, segundos: 2))
            assertTest(inits() == 1, "Quadro-chave de rotina com o mesmo SPS/PPS não gera init novo (inits: \(inits()))")
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: true, segundos: 4, sps: 0x28))
            assertTest(inits() == 2, "SPS diferente (mesma resolução) gera init novo (inits: \(inits()))")
            pacote.reset()
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: false, segundos: 5))
            assertTest(inits() == 2, "Depois do reset(), P-frame sozinho não emite nada")
            pacote.didReceiveAccessUnit(unidadeSintetica(chave: true, segundos: 6, sps: 0x28))
            assertTest(inits() == 3, "Depois do reset(), o próximo quadro-chave emite init novo (inits: \(inits()))")
            let frags = coletor.fragmentos
            assertTest(frags.last?.isInitSegment == false && frags[frags.count - 2].isInitSegment,
                       "Na segunda sessão o init vem antes do primeiro fragmento de mídia")
            if let ultimo = frags.last?.data, let seq = ultimo.range(of: Data("mfhd".utf8)) {
                assertTest(inteiroBE(ultimo, seq.upperBound - ultimo.startIndex + 4, 4) == 1,
                           "Sequência do fragmento recomeça em 1 depois do reset()")
            }
        }

        // Fragmentos de teste com marcador no começo (para achar na conexão) e tamanho livre.
        func fragmentoMarcado(_ marca: String, tamanho: Int = 0) -> Data {
            Data(marca.utf8) + Data(repeating: 0x5A, count: tamanho)
        }
        func abrirMP4Bruto(_ porta: UInt16, bufferDeRecepcao: Int32? = nil) -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if var tam = bufferDeRecepcao {
                setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &tam, socklen_t(MemoryLayout<Int32>.size))
            }
            var destino = sockaddr_in()
            destino.sin_family = sa_family_t(AF_INET)
            destino.sin_port = in_port_t(porta.bigEndian)
            destino.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &destino) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            _ = "GET /stream.mp4 HTTP/1.1\r\nHost: x\r\n\r\n".withCString { send(fd, $0, strlen($0), 0) }
            return fd
        }
        func lerDisponivel(_ fd: Int32) -> Data {
            var dados = Data()
            var pedaco = [UInt8](repeating: 0, count: 262_144)
            while true {
                let n = recv(fd, &pedaco, pedaco.count, MSG_DONTWAIT)
                if n <= 0 { break }
                dados.append(contentsOf: pedaco[0..<n])
            }
            return dados
        }
        func posicao(_ marca: String, em dados: Data) -> Int? {
            dados.range(of: Data(marca.utf8)).map { $0.lowerBound - dados.startIndex }
        }

        // (5) cabeçalho antes do init, mesmo com publicações concorrentes; (e) entrada no meio do stream
        let servidorOrdem = NetworkListenerService(port: 8140, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorOrdem.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            servidorOrdem.broadcastVideoFragment(fragmentoMarcado("INIT-A"), isInitSegment: true, isKeyFrame: true)
            servidorOrdem.broadcastVideoFragment(fragmentoMarcado("KEY-1"), isInitSegment: false, isKeyFrame: true)
            servidorOrdem.broadcastVideoFragment(fragmentoMarcado("PFR-1"), isInitSegment: false, isKeyFrame: false)

            let fdMeio = abrirMP4Bruto(8140)
            try? await Task.sleep(nanoseconds: 300_000_000)
            servidorOrdem.broadcastVideoFragment(fragmentoMarcado("PFR-2"), isInitSegment: false, isKeyFrame: false)
            servidorOrdem.broadcastVideoFragment(fragmentoMarcado("KEY-2"), isInitSegment: false, isKeyFrame: true)
            servidorOrdem.broadcastVideoFragment(fragmentoMarcado("PFR-3"), isInitSegment: false, isKeyFrame: false)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let recebidoMeio = lerDisponivel(fdMeio)
            let pHeader = posicao("HTTP/1.1 200", em: recebidoMeio)
            let pInit = posicao("INIT-A", em: recebidoMeio)
            let pK2 = posicao("KEY-2", em: recebidoMeio)
            let pP3 = posicao("PFR-3", em: recebidoMeio)
            assertTest(pHeader == 0, "Aluno que entra no meio: o cabeçalho HTTP é o primeiro byte")
            assertTest(pInit != nil && pK2 != nil && pInit! < pK2!, "Aluno no meio recebe init e depois o quadro-chave")
            assertTest(pP3 != nil && pK2 != nil && pK2! < pP3!, "...e os P-frames seguintes, em ordem")
            assertTest(posicao("KEY-1", em: recebidoMeio) == nil && posicao("PFR-1", em: recebidoMeio) == nil
                       && posicao("PFR-2", em: recebidoMeio) == nil,
                       "Aluno no meio não recebe quadros anteriores ao seu primeiro quadro-chave")
            close(fdMeio)

            // Corrida: publica sem parar enquanto conexões novas chegam; o primeiro byte tem que ser o cabeçalho.
            let parar = NSLock()
            nonisolated(unsafe) var continuar = true
            let publicador = DispatchQueue(label: "teste.publicador")
            publicador.async {
                while true {
                    parar.lock(); let seguir = continuar; parar.unlock()
                    if !seguir { break }
                    servidorOrdem.broadcastVideoFragment(fragmentoMarcado("KEY-R"), isInitSegment: false, isKeyFrame: true)
                    usleep(300)
                }
            }
            var todosComCabecalhoPrimeiro = true
            for _ in 0..<8 {
                let fd = abrirMP4Bruto(8140)
                try? await Task.sleep(nanoseconds: 250_000_000)
                let r = lerDisponivel(fd)
                if posicao("HTTP/1.1 200", em: r) != 0 { todosComCabecalhoPrimeiro = false }
                close(fd)
            }
            parar.lock(); continuar = false; parar.unlock()
            assertTest(todosComCabecalhoPrimeiro, "Com publicação concorrente, 'HTTP/1.1 200' sempre sai antes do init/fragmentos")
            servidorOrdem.stop()
        } catch {
            assertTest(false, "Falha no teste de ordem da rota /stream.mp4: \(error.localizedDescription)")
        }

        // (7) pedidos de quadro-chave agrupados
        let servidorRate = NetworkListenerService(port: 8141, webAssetsPath: FileManager.default.temporaryDirectory)
        let pedidosRate = ContadorDePedidos()
        servidorRate.onVideoViewerNeedsKeyFrame = { pedidosRate.pedir() }
        do {
            try servidorRate.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            for _ in 0..<20 {
                close(abrirMP4Bruto(8141))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            assertTest(pedidosRate.pedidos == 1, "20 conexões em rajada: 1 pedido imediato (veio \(pedidosRate.pedidos))")
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            assertTest(pedidosRate.pedidos == 2, "O pedido dentro da janela é adiado, não perdido: 2 no total (veio \(pedidosRate.pedidos))")
            servidorRate.stop()
        } catch {
            assertTest(false, "Falha no teste de agrupamento dos pedidos: \(error.localizedDescription)")
        }

        // (6) conexão fechada sai de `conexoes` mesmo sem nenhum quadro fluindo
        let servidorSaida = NetworkListenerService(port: 8142, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorSaida.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let fd = abrirMP4Bruto(8142)
            var n = 0
            for _ in 0..<20 where n < 1 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                n = servidorSaida.activeStreamCount
            }
            assertTest(n == 1, "Aluno H.264 conectado é contado em activeStreamCount (veio \(n))")
            close(fd)
            var sobrou = servidorSaida.activeStreamCount
            for _ in 0..<20 where sobrou > 0 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                sobrou = servidorSaida.activeStreamCount
            }
            assertTest(sobrou == 0, "Fechou sem nenhum quadro publicado: activeStreamCount volta a 0 (sobrou \(sobrou))")
            assertTest(servidorSaida.streamSnapshot().quadrosPorAluno.isEmpty, "...e o contador do aluno some do snapshot")
            servidorSaida.stop()
        } catch {
            assertTest(false, "Falha no teste de saída sem quadros: \(error.localizedDescription)")
        }

        // (9) contadores do snapshot e chaves mescladas
        let servidorSnap = NetworkListenerService(port: 8143, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorSnap.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let fd = abrirMP4Bruto(8143)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let tamanhos = [3000, 500, 700]
            servidorSnap.broadcastVideoFragment(fragmentoMarcado("INIT-S", tamanho: 200), isInitSegment: true, isKeyFrame: true)
            servidorSnap.broadcastVideoFragment(fragmentoMarcado("K", tamanho: tamanhos[0]), isInitSegment: false, isKeyFrame: true)
            servidorSnap.broadcastVideoFragment(fragmentoMarcado("P", tamanho: tamanhos[1]), isInitSegment: false, isKeyFrame: false)
            servidorSnap.broadcastVideoFragment(fragmentoMarcado("P", tamanho: tamanhos[2]), isInitSegment: false, isKeyFrame: false)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let snap = servidorSnap.streamSnapshot()
            assertTest(snap.quadrosPublicados == 3, "quadrosPublicados conta só fragmentos de mídia (veio \(snap.quadrosPublicados))")
            assertTest(snap.bytesEnviados >= UInt64(tamanhos.reduce(0, +) + 200),
                       "bytesEnviados soma tudo que saiu (veio \(snap.bytesEnviados))")
            assertTest(snap.quadrosPorAluno.count == 1 && snap.quadrosPorAluno.values.first == 3,
                       "O aluno conta 3 fragmentos de mídia, sem o init (veio \(Array(snap.quadrosPorAluno.values)))")
            assertTest(snap.quadrosPorAluno.keys.allSatisfy { $0 & NetworkListenerService.marcaDeAlunoMP4 != 0 },
                       "Chaves dos alunos H.264 vêm marcadas no snapshot mesclado")
            _ = lerDisponivel(fd)
            close(fd)
            servidorSnap.stop()
        } catch {
            assertTest(false, "Falha no teste dos contadores H.264: \(error.localizedDescription)")
        }
        do {
            var mjpeg = StreamSnapshot()
            mjpeg.quadrosPublicados = 10; mjpeg.bytesEnviados = 1000; mjpeg.quadrosPorAluno = [1: 5, 2: 6]
            var mp4 = StreamSnapshot()
            mp4.quadrosPublicados = 12; mp4.bytesEnviados = 500; mp4.quadrosPorAluno = [1: 7]
            let junto = NetworkListenerService.mesclar(mjpeg: mjpeg, mp4: mp4)
            assertTest(junto.quadrosPorAluno.count == 3, "Mesclado: mesmo id 1 nas duas rotas não colide (3 alunos)")
            assertTest(junto.quadrosPublicados == 12, "Mesclado: quadros publicados = máximo, não soma (\(junto.quadrosPublicados))")
            assertTest(junto.bytesEnviados == 1500, "Mesclado: bytes somam")
            assertTest(junto.quadrosPorAluno[1] == 5 && junto.quadrosPorAluno[1 | NetworkListenerService.marcaDeAlunoMP4] == 7,
                       "Mesclado: cada aluno mantém o próprio contador")
        }

        // (8) cliente lento: fila por bytes estoura, descarta, pede quadro-chave e ressincroniza
        let servidorLento = NetworkListenerService(port: 8144, webAssetsPath: FileManager.default.temporaryDirectory)
        let pedidosLento = ContadorDePedidos()
        servidorLento.onVideoViewerNeedsKeyFrame = { pedidosLento.pedir() }
        do {
            try servidorLento.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let fd = abrirMP4Bruto(8144, bufferDeRecepcao: 4096)
            try? await Task.sleep(nanoseconds: 300_000_000)
            servidorLento.broadcastVideoFragment(fragmentoMarcado("INIT-L"), isInitSegment: true, isKeyFrame: true)
            servidorLento.broadcastVideoFragment(fragmentoMarcado("KEY-L0", tamanho: 900_000), isInitSegment: false, isKeyFrame: true)
            for _ in 0..<12 {
                servidorLento.broadcastVideoFragment(fragmentoMarcado("PFR-L", tamanho: 900_000), isInitSegment: false, isKeyFrame: false)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Havia um quadro-chave publicado há menos de 2 s: o estouro não pede outro (evita o laço
            // "aluno lento -> quadro-chave para a turma"); só o pedido da conexão nova conta.
            assertTest(pedidosLento.pedidos == 1, "Estouro da fila com quadro-chave recente não pede outro (pedidos: \(pedidosLento.pedidos))")
            assertTest(servidorLento.activeStreamCount == 1, "O aluno lento continua conectado (só ressincroniza)")

            // Ele volta a ler e um quadro-chave novo o ressincroniza.
            servidorLento.broadcastVideoFragment(fragmentoMarcado("KEY-FINAL"), isInitSegment: false, isKeyFrame: true)
            var achou = false
            var acumulado = Data()
            for _ in 0..<60 where !achou {
                try? await Task.sleep(nanoseconds: 100_000_000)
                acumulado.append(lerDisponivel(fd))
                achou = acumulado.range(of: Data("KEY-FINAL".utf8)) != nil
            }
            assertTest(achou, "Depois de ler de novo, o aluno lento recebe o próximo quadro-chave")
            close(fd)
            servidorLento.stop()
        } catch {
            assertTest(false, "Falha no teste do cliente lento: \(error.localizedDescription)")
        }

        // (10) taxa de bits alvo
        assertTest(H264FrameEncoder.taxaMediaBps(largura: 1920, altura: 1080, fps: 30) == 2_488_320,
                   "Taxa média alvo em 1080p30 ≈ 2,5 Mbps")
        assertTest(H264FrameEncoder.taxaMediaBps(largura: 640, altura: 360, fps: 15) == 1_200_000,
                   "Taxa média alvo tem piso de 1,2 Mbps")
        assertTest(H264FrameEncoder.taxaMediaBps(largura: 3840, altura: 2160, fps: 60) == 4_000_000,
                   "Taxa média alvo tem teto de 4 Mbps")

        // (11) Teto de duração derivado do fps real: a 15 fps, 2 períodos = 12000 ticks (não 6000).
        do {
            let coletor = ColetorDeFragmentos()
            let pacote = FMP4Packager()
            pacote.outputReceiver = coletor
            func au15(chave: Bool, segundos: Double) -> H264AccessUnit {
                let base = unidadeSintetica(chave: chave, segundos: segundos)
                return H264AccessUnit(data: base.data, presentationTime: base.presentationTime, isKeyFrame: chave,
                                      width: base.width, height: base.height, framesPerSecond: 15)
            }
            pacote.didReceiveAccessUnit(au15(chave: true, segundos: 0))
            pacote.didReceiveAccessUnit(au15(chave: false, segundos: 30))
            pacote.didReceiveAccessUnit(au15(chave: false, segundos: 30.07))
            let duracoes = coletor.fragmentos.filter { !$0.isInitSegment }.compactMap { duracaoDoFragmento($0.data) }
            assertTest(duracoes == [6000, 12000, 6300],
                       "Teto de 2 períodos usa o fps real (15 fps => 12000 ticks; veio \(duracoes))")
        }

        // (12) Quadro-chave pedido com a tela parada re-codifica o último quadro; reset() o esquece.
        do {
            let coletor = ColetorDeAccessUnits()
            let encoder = H264FrameEncoder()
            encoder.h264OutputReceiver = coletor
            for indice in 0..<4 {
                if let amostra = criarAmostraH264(indice: indice) { encoder.encode(sampleBuffer: amostra) }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let antes = coletor.unidades.count
            assertTest(antes >= 1, "Encoder de tela parada: já entregou quadros antes do pedido (\(antes))")

            encoder.forceNextKeyFrame() // sem nenhum quadro novo chegando
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let depois = coletor.unidades
            assertTest(depois.count > antes && depois.last?.isKeyFrame == true,
                       "Pedido de quadro-chave com a tela parada gera um IDR do último quadro (\(antes) -> \(depois.count))")
            if let ultimaChave = depois.last, let anterior = depois.dropLast().last {
                assertTest(CMTimeCompare(ultimaChave.presentationTime, anterior.presentationTime) > 0,
                           "O IDR re-codificado tem PTS monotônico")
            }

            encoder.reset()
            let aposReset = coletor.unidades.count
            encoder.forceNextKeyFrame()
            try? await Task.sleep(nanoseconds: 600_000_000)
            assertTest(coletor.unidades.count == aposReset,
                       "Depois de reset(), o pedido não reenvia a tela da sessão anterior")
        }

        // (13) Limite de conexões /stream.mp4 por IP: a 5ª do mesmo IP é fechada na hora.
        let servidorLimite = NetworkListenerService(port: 8150, webAssetsPath: FileManager.default.temporaryDirectory)
        do {
            try servidorLimite.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            servidorLimite.broadcastVideoFragment(fragmentoMarcado("INIT-L"), isInitSegment: true, isKeyFrame: true)
            let fds = (0..<5).map { _ in abrirMP4Bruto(8150) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let respostas = fds.map { String(decoding: lerDisponivel($0), as: UTF8.self) }
            let aceitas = respostas.filter { $0.contains("200 OK") }.count
            assertTest(aceitas == 4, "Limite por IP: só 4 conexões /stream.mp4 de 127.0.0.1 são atendidas (atendidas: \(aceitas))")
            assertTest(servidorLimite.activeStreamCount == 4, "Limite por IP: 4 alunos ativos (\(servidorLimite.activeStreamCount))")
            fds.forEach { close($0) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let fdNovo = abrirMP4Bruto(8150)
            try? await Task.sleep(nanoseconds: 400_000_000)
            assertTest(String(decoding: lerDisponivel(fdNovo), as: UTF8.self).contains("200 OK"),
                       "Liberadas as conexões, uma nova do mesmo IP volta a ser atendida")
            close(fdNovo)
            servidorLimite.stop()
        } catch {
            assertTest(false, "Falha no teste de limite de conexões: \(error.localizedDescription)")
        }

        // (14b) DEBUG_INFO: uma vez, logo depois do CONNECTED, só com as chaves esperadas.
        print("\n--- DEBUG_INFO ---")
        do {
            let servidorDebug = NetworkListenerService(port: 8170, webAssetsPath: FileManager.default.temporaryDirectory)
            try? servidorDebug.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8170/ws")!)
            ws.resume()
            var tipos: [String] = []
            var infoDebug: [String: Any] = [:]
            for _ in 0..<2 {
                guard case .string(let t)? = try? await ws.receive(), let d = t.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { break }
                tipos.append(j["type"] as? String ?? "?")
                if j["type"] as? String == "DEBUG_INFO" { infoDebug = j["payload"] as? [String: Any] ?? [:] }
            }
            assertTest(tipos == ["CONNECTED", "DEBUG_INFO"], "DEBUG_INFO vem uma vez, logo depois do CONNECTED (\(tipos))")
            let esperadas: Set<String> = ["versao", "porta", "ip", "h264", "h264TaxaMinBps", "h264TaxaMaxBps", "quadroChaveMaxSeg",
                                          "maxMp4PorIp", "maxMp4Total", "filaMaxBytes", "filaMaxMs", "pedidoQuadroChaveMs"]
            assertTest(Set(infoDebug.keys) == esperadas, "DEBUG_INFO traz só as chaves esperadas (\(Set(infoDebug.keys).symmetricDifference(esperadas)))")
            assertTest(infoDebug["porta"] as? Int == 8170 && infoDebug["maxMp4PorIp"] as? Int == 4 && infoDebug["maxMp4Total"] as? Int == 120,
                       "DEBUG_INFO: porta e limites de conexão")
            let volta = try? JSONSerialization.data(withJSONObject: infoDebug)
            assertTest((volta.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?.count == esperadas.count,
                       "DEBUG_INFO sobrevive ao ciclo JSON")
            ws.cancel(with: .goingAway, reason: nil)
            servidorDebug.stop()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // (14) Métricas por aluno: METRICS validado, guardado e devolvido no METRICS_TABLE.
        print("\n--- Métricas: METRICS e METRICS_TABLE ---")
        do {
            // Unidade: validação estrita e limite de 1 mensagem por segundo (relógio injetado).
            var relogio = Date(timeIntervalSince1970: 1_000)
            let livro = StudentMetricsBook(agora: { relogio })
            let valido: [String: Any] = ["rota": "H.264", "fps": 30, "mbps": "2.5", "dropped": 3, "lagMs": 200]
            assertTest(livro.registrar(clientId: "a", payload: valido), "METRICS válido é aceito")
            assertTest(livro.relatorio(clientId: "a") == StudentMetricsReport(rota: "H.264", fps: 30, mbps: 2.5, dropped: 3, lagMs: 200),
                       "METRICS aceito guarda os números")
            relogio = relogio.addingTimeInterval(0.5)
            assertTest(!livro.registrar(clientId: "a", payload: ["rota": "MJPEG"]), "Limite: 2ª mensagem em menos de 1 s é ignorada")
            relogio = relogio.addingTimeInterval(1)
            assertTest(livro.registrar(clientId: "a", payload: ["rota": "MJPEG", "fps": NSNull()]), "Passado 1 s, volta a aceitar (MJPEG com nulos)")
            assertTest(livro.relatorio(clientId: "a")?.fps == nil, "MJPEG fica sem números")
            relogio = relogio.addingTimeInterval(2)
            assertTest(!livro.registrar(clientId: "b", payload: ["rota": "VP9"]), "Rota desconhecida é ignorada")
            assertTest(!livro.registrar(clientId: "b", payload: ["rota": "H.264", "extra": 1]), "Chave desconhecida invalida a mensagem")
            assertTest(!livro.registrar(clientId: "b", payload: ["rota": "H.264", "fps": "abc"]), "Número inválido é ignorado")
            assertTest(!livro.registrar(clientId: "b", payload: ["rota": "H.264", "fps": true]), "Booleano no lugar de número é ignorado")
            assertTest(!livro.registrar(clientId: "b", payload: ["rota": "H.264", "fps": "inf"]), "Valor infinito é ignorado")
            assertTest(!livro.registrar(clientId: "b", payload: nil), "Sem payload é ignorado")
            assertTest(livro.registrar(clientId: "b", payload: ["rota": "H.264", "fps": 99999, "mbps": -5, "dropped": -1, "lagMs": 1e12]),
                       "Valores fora da faixa são aceitos, mas limitados")
            assertTest(livro.relatorio(clientId: "b") == StudentMetricsReport(rota: "H.264", fps: 240, mbps: 0, dropped: 0, lagMs: 3_600_000),
                       "Faixas: fps 0-240, mbps 0-1000, dropped >= 0, lagMs 0-3600000")
            livro.remover(clientId: "a")
            assertTest(livro.relatorio(clientId: "a") == nil, "Remover na desconexão apaga a linha")
            let muitos = StudentMetricsBook(agora: { relogio })
            var nomesMuitos: [String: String] = [:]
            for i in 0..<(StudentMetricsBook.maxLinhas + 20) {
                muitos.registrar(clientId: "c\(i)", payload: ["rota": "MJPEG"])
                nomesMuitos["c\(i)"] = "Aluno \(i)"
            }
            assertTest(muitos.linhas(nomes: nomesMuitos).count == StudentMetricsBook.maxLinhas, "Tabela limitada a \(StudentMetricsBook.maxLinhas) linhas")

            // Ponta a ponta com WebSocket real.
            let pastaMetricas = FileManager.default.temporaryDirectory.appendingPathComponent("aulacast-metricas-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: pastaMetricas) }
            let servidorMetricas = NetworkListenerService(port: 8160, webAssetsPath: FileManager.default.temporaryDirectory)
            servidorMetricas.diretorioDeMetricas = pastaMetricas
            try servidorMetricas.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let zero = StreamSnapshot()
            let taxaVazia = StreamRates.entre(zero, e: zero, segundos: 5)!

            var boasVindasMetricas = ""
            func abrir() async -> URLSessionWebSocketTask {
                let s = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8160/ws")!)
                s.resume()
                if case .string(let t)? = try? await s.receive() { boasVindasMetricas = t } // CONNECTED
                return s
            }
            func esperarTabela(_ s: URLSessionWebSocketTask) async -> [String: Any]? {
                for _ in 0..<8 {
                    guard case .string(let t)? = try? await s.receive() else { return nil }
                    if let d = t.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       j["type"] as? String == "METRICS_TABLE" { return j["payload"] as? [String: Any] }
                }
                return nil
            }
            let ana = await abrir()
            assertTest(MetricasDebug.consoleAtivo, "Build de depuração (o do runner): MetricasDebug.consoleAtivo é verdadeiro")
            assertTest(boasVindasMetricas.contains("\"metricas\":\"true\""), "CONNECTED avisa o navegador de que as métricas estão ligadas")
            let intruso = await abrir()
            let saida = await abrir()
            try? await ana.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Ana \\\"A\\\"\\nB\"}}"))
            try? await saida.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Saiu\"}}"))
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await ana.send(.string("{\"type\":\"METRICS\",\"payload\":{\"rota\":\"H.264\",\"fps\":29.5,\"mbps\":2.25,\"dropped\":2,\"lagMs\":150}}"))
            try? await ana.send(.string("{\"type\":\"METRICS\",\"payload\":{\"rota\":\"H.264\",\"fps\":1,\"mbps\":1,\"dropped\":1,\"lagMs\":1}}"))
            try? await saida.send(.string("{\"type\":\"METRICS\",\"payload\":{\"rota\":\"H.264\",\"fps\":10}}"))
            try? await intruso.send(.string("{\"type\":\"METRICS\",\"payload\":{\"rota\":\"H.264\",\"fps\":60}}"))
            try? await Task.sleep(nanoseconds: 400_000_000)

            servidorMetricas.publicarMetricas(taxaVazia)
            let tabela = await esperarTabela(ana)
            let linhas = tabela?["rows"] as? [[String: Any]] ?? []
            let linhaAna = linhas.first { ($0["nome"] as? String) == "Ana \"A\"\nB" }
            assertTest(tabela != nil, "Aluno recebe METRICS_TABLE")
            assertTest(linhaAna != nil, "Nome com aspas e quebra de linha volta íntegro no JSON da tabela")
            assertTest(linhaAna?["fps"] as? Double == 29.5 && linhaAna?["lagMs"] as? Int == 150,
                       "A tabela traz a 1ª medição; a 2ª, colada, foi ignorada pelo limite de 1/s")
            assertTest(linhas.count == 2, "Só alunos identificados aparecem (linhas: \(linhas.count))")
            assertTest(tabela?["alunosH264"] != nil && tabela?["telaFps"] != nil && tabela?["mbps"] != nil,
                       "A tabela traz o resumo do servidor")
            assertTest(tabela?["estourosDeFila"] != nil && tabela?["pedidosDeQuadroChave"] != nil && tabela?["bytesTotais"] != nil,
                       "A tabela traz os contadores de fila, pedidos de quadro-chave e bytes totais")

            saida.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(nanoseconds: 600_000_000)
            servidorMetricas.publicarMetricas(taxaVazia)
            let depois = await esperarTabela(ana)
            let nomesDepois = (depois?["rows"] as? [[String: Any]] ?? []).compactMap { $0["nome"] as? String }
            assertTest(nomesDepois == ["Ana \"A\"\nB"], "Quem desconecta sai da tabela (\(nomesDepois))")
            ana.cancel(with: .goingAway, reason: nil)
            intruso.cancel(with: .goingAway, reason: nil)
            let caminhoSessao = servidorMetricas.caminhoDoArquivoDeMetricas
            servidorMetricas.stop()

            // Arquivo da sessão (JSONL) escrito pelo servidor.
            let nomeArquivo = caminhoSessao?.lastPathComponent ?? ""
            assertTest(nomeArquivo.range(of: #"^sessao-\d{8}-\d{6}\.jsonl$"#, options: .regularExpression) != nil,
                       "Arquivo da sessão: sessao-AAAAMMDD-HHmmss.jsonl (\(nomeArquivo))")
            let objetos: [[String: Any]] = ((try? String(contentsOf: caminhoSessao ?? pastaMetricas, encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let tipos = objetos.compactMap { $0["tipo"] as? String }
            assertTest(tipos.first == "legenda" && tipos.dropFirst().first == "inicio" && objetos[1]["porta"] as? Int == 8160, "Arquivo: legenda, depois inicio com a porta")
            assertTest(tipos.last == "fim", "Arquivo: última linha é 'fim'")
            assertTest(tipos.filter { $0 == "entrada" }.count == 2 && tipos.contains("saida"), "Arquivo: entrada e saída de alunos identificados")
            let amostra = objetos.first { $0["tipo"] as? String == "amostra" }
            let linhasAluno = objetos.filter { $0["tipo"] as? String == "aluno" }
            assertTest(amostra != nil && amostra?["estourosDeFila"] != nil && amostra?["pedidosDeQuadroChave"] != nil
                       && linhasAluno.contains { $0["nome"] as? String == "Ana \"A\"\nB" && $0["reportadoHa"] != nil },
                       "Arquivo: amostra traz contadores e o detalhe por aluno com reportadoHa")
            assertTest(objetos.last?["picoAlunos"] as? Int == 2, "Arquivo: 'fim' traz o pico de alunos")

            // Unidade do logger: perda estimada, truncamento e erro de disco.
            assertTest(abs((MetricsFileLogger.perdaEstimadaPct(telaFps: 30, mediaFps: 24) ?? -1) - 20) < 1e-9, "perdaEstimadaPct: 30 vs 24 fps = 20%")
            assertTest(MetricsFileLogger.perdaEstimadaPct(telaFps: 0, mediaFps: 0) == nil, "perdaEstimadaPct: tela parada = null")
            assertTest(MetricsFileLogger.perdaEstimadaPct(telaFps: 30, mediaFps: 45) == 0, "perdaEstimadaPct: limitada a 0")
            assertTest(MetricsFileLogger.perdaEstimadaPct(telaFps: 30, mediaFps: -30) == 100, "perdaEstimadaPct: limitada a 100")

            let pastaTrunc = pastaMetricas.appendingPathComponent("trunc")
            let curto = MetricsFileLogger(diretorio: pastaTrunc, limiteBytes: 300)
            curto.iniciar(porta: 1)
            for i in 0..<20 { curto.registrarEvento("entrada", nome: "Aluno \(i)") }
            curto.encerrar()
            let linhasTrunc = ((try? String(contentsOf: curto.arquivo!, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            assertTest(linhasTrunc.filter { $0.contains("\"tipo\":\"truncado\"") }.count == 1, "Limite de tamanho: uma única linha 'truncado'")
            assertTest(linhasTrunc.filter { $0.contains("entrada") }.count < 20, "Limite de tamanho: para de anexar")

            let semAcesso = MetricsFileLogger(diretorio: URL(fileURLWithPath: "/proc-inexistente/x/y"))
            semAcesso.iniciar(porta: 1)
            semAcesso.registrarEvento("entrada", nome: "Ana")
            semAcesso.encerrar()
            assertTest(semAcesso.arquivo == nil, "Erro de disco: não derruba nem cria arquivo")
        } catch {
            assertTest(false, "Falha no teste de métricas: \(error.localizedDescription)")
        }

        } else { placar.puladas.append("T33-T35 + DEBUG_INFO + Métricas (H.264/rede)") }

        // TESTE 36: Onde o app procura o frontend (web-assets).
        print("\n--- [36/36] Testes de Domínio: caminho do web-assets ---")
        let pastaDoProjeto = URL(fileURLWithPath: "/Users/prof/AulaCast")
        let appEmpacotado = URL(fileURLWithPath: "/Users/prof/Downloads/AulaCast.app")
        let recursos = URL(fileURLWithPath: "/Users/prof/Downloads/AulaCast.app/Contents/Resources")
        let empacotadoCand = WebAssetsPathResolver.candidatos(currentDir: pastaDoProjeto, bundleURL: appEmpacotado, resourceURL: recursos)
        assertTest(empacotadoCand.first?.path == "/Users/prof/Downloads/AulaCast.app/Contents/Resources/web-assets",
                   "Rodando como .app, o frontend de dentro do app vence a pasta onde ele foi iniciado")
        let soltoCand = WebAssetsPathResolver.candidatos(
            currentDir: URL(fileURLWithPath: "/Users/prof/AulaCast/src"),
            bundleURL: URL(fileURLWithPath: "/Users/prof/AulaCast/src/.build/debug/AulaCast"),
            resourceURL: nil
        )
        assertTest(soltoCand.first?.path == "/Users/prof/AulaCast/src/web-assets",
                   "Rodando solto (swift run), a pasta de trabalho continua sendo a primeira")

        print("\n--- [37/37] Testes de Domínio: tempo de cada aluno na aula (RF-20) ---")

        let base0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func emp(_ s: TimeInterval) -> Date { base0.addingTimeInterval(s) }
        func resumoDe(_ l: AttendanceLedger, _ id: String, _ s: TimeInterval) -> AttendanceSummary? {
            l.resumo(clientId: id, agora: emp(s))
        }

        // Só conta com a aula correndo.
        let lAntes = AttendanceLedger(clock: { base0 })
        lAntes.connected(clientId: "a", ip: "10.0.0.1", at: emp(0))
        assertTest(resumoDe(lAntes, "a", 30)?.naAula == 0, "Antes de transmitir nada é contado")
        lAntes.setAccruing(true, at: emp(30))
        assertTest(resumoDe(lAntes, "a", 40)?.naAula == 10, "Quem já estava conectado começa a contar quando a transmissão começa")

        // Totais, pausa, visível/oculto, saídas e maior trecho.
        let l = AttendanceLedger(clock: { base0 })
        l.setAccruing(true, at: emp(0))
        l.connected(clientId: "a", ip: "10.0.0.1", at: emp(0))
        l.identified(clientId: "a", name: "Ana", at: emp(0))
        l.visibility(clientId: "a", visible: false, at: emp(10))
        l.visibility(clientId: "a", visible: true, at: emp(20))
        var r = resumoDe(l, "a", 50)
        assertTest(r?.naAula == 50 && r?.aVista == 40, "Na aula 50 s, à vista 40 s (10 s em outra aba)")
        assertTest(r?.saidas == 1, "Uma saída: visível para oculto")
        assertTest(r?.maiorTrecho == 30, "Maior trecho = 30 s (o trecho atual, ainda aberto)")
        l.setAccruing(false, at: emp(50))
        assertTest(resumoDe(l, "a", 500)?.naAula == 50, "Em pausa o relógio congela nos dois totais")
        l.setAccruing(true, at: emp(500))
        r = resumoDe(l, "a", 510)
        assertTest(r?.naAula == 60 && r?.aVista == 50, "Depois da pausa volta a somar do ponto em que parou")
        assertTest(r?.maiorTrecho == 40, "A pausa não quebra o trecho contínuo (30 + 10 = 40 s)")
        assertTest(formatarDuracao(0) == "0 s" && formatarDuracao(59) == "59 s", "formatarDuracao: 0 s e 59 s")
        assertTest(formatarDuracao(61) == "1 min 01 s", "formatarDuracao: 61 s")
        assertTest(formatarDuracao(42 * 60 + 10) == "42 min 10 s", "formatarDuracao: 42 min 10 s")
        assertTest(formatarDuracao(3720) == "1 h 02 min", "formatarDuracao: 1 h 02 min")
        assertTest(resumoDe(l, "a", 510)?.fracaoAVista == 50.0 / 60.0, "Fração à vista / na aula")
        assertTest(AttendanceLedger(clock: { base0 }).resumo(clientId: "x") == nil, "Aluno desconhecido não tem resumo")

        // Saída ao desconectar visível; mesmo IP com outro nome é a mesma pessoa (1 desconexão).
        let lIP = AttendanceLedger(clock: { base0 })
        lIP.setAccruing(true, at: emp(0))
        lIP.connected(clientId: "c1", ip: "10.0.0.5", at: emp(0))
        lIP.identified(clientId: "c1", name: "Ana", at: emp(0))
        lIP.disconnected(clientId: "c1", at: emp(10))
        lIP.connected(clientId: "c2", ip: "10.0.0.5", at: emp(20))
        lIP.identified(clientId: "c2", name: "Aninha", at: emp(20))
        let rIP = resumoDe(lIP, "c2", 30)
        assertTest(rIP?.desconexoes == 1 && rIP?.saidas == 1, "Mesmo IP, outro nome: mesma pessoa, 1 desconexão e 1 saída")
        assertTest(rIP?.naAula == 20 && rIP?.nome == "Aninha", "Soma os dois períodos (10 + 10 s) e mostra o nome mais recente")

        // Nome igual com outro IP, sem conexão aberta: junta. Com conexão aberta: homônimos.
        let lNome = AttendanceLedger(clock: { base0 })
        lNome.setAccruing(true, at: emp(0))
        lNome.connected(clientId: "n1", ip: "10.0.0.7", at: emp(0))
        lNome.identified(clientId: "n1", name: "José Álvares", at: emp(0))
        lNome.disconnected(clientId: "n1", at: emp(10))
        lNome.connected(clientId: "n2", ip: "10.0.0.8", at: emp(20))
        lNome.identified(clientId: "n2", name: "  jose   ALVARES ", at: emp(20))
        let rNome = resumoDe(lNome, "n2", 25)
        assertTest(rNome?.desconexoes == 1 && rNome?.naAula == 15, "Mesmo nome (sem acento/caixa/espaços), outro IP: junta (10 + 5 s)")

        let lHom = AttendanceLedger(clock: { base0 })
        lHom.setAccruing(true, at: emp(0))
        lHom.connected(clientId: "h1", ip: "10.0.0.1", at: emp(0))
        lHom.identified(clientId: "h1", name: "Maria", at: emp(0))
        lHom.connected(clientId: "h2", ip: "10.0.0.2", at: emp(5))
        lHom.identified(clientId: "h2", name: "maria", at: emp(5))
        assertTest(resumoDe(lHom, "h1", 10)?.naAula == 10 && resumoDe(lHom, "h2", 10)?.naAula == 5,
                   "Homônimos em IPs diferentes ao mesmo tempo são duas pessoas")

        // Duas abas da mesma pessoa não contam em dobro.
        let lAbas = AttendanceLedger(clock: { base0 })
        lAbas.setAccruing(true, at: emp(0))
        lAbas.connected(clientId: "t1", ip: "10.0.0.9", at: emp(0))
        lAbas.connected(clientId: "t2", ip: "10.0.0.9", at: emp(0))
        lAbas.visibility(clientId: "t2", visible: false, at: emp(5))
        let rAbas = resumoDe(lAbas, "t1", 10)
        assertTest(rAbas?.naAula == 10 && rAbas?.aVista == 10, "Duas abas contam uma vez; uma visível basta para estar à vista")
        assertTest(rAbas?.saidas == 0 && rAbas?.desconexoes == 0, "Esconder uma de duas abas não é saída nem desconexão")

        // reset: mantém conectados, zera números, esquece quem saiu.
        let lRes = AttendanceLedger(clock: { base0 })
        lRes.setAccruing(true, at: emp(0))
        lRes.connected(clientId: "r1", ip: "10.0.0.1", at: emp(0))
        lRes.connected(clientId: "r2", ip: "10.0.0.2", at: emp(0))
        lRes.disconnected(clientId: "r2", at: emp(5))
        lRes.reset(at: emp(10))
        assertTest(resumoDe(lRes, "r1", 10)?.naAula == 0, "reset zera os números de quem segue conectado")
        assertTest(resumoDe(lRes, "r1", 14)?.naAula == 4, "reset mantém quem estava conectado e continua contando")
        lRes.connected(clientId: "r3", ip: "10.0.0.2", at: emp(20))
        assertTest(resumoDe(lRes, "r3", 20)?.desconexoes == 0, "reset esquece quem tinha saído (volta como pessoa nova)")

        // alunoAberto: abre e fecha sozinho quando o aluno desconecta.
        let vmLedger = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: FakeServer(),
            advertiserService: FakeAdvertiser(),
            systemActivity: FakeSystemActivity(),
            permission: FakePermission(concedida: true),
            hostnameService: FakeHostname()
        )
        let alunoPainel = ConnectedClient(id: "painel-1", name: "Aluno", ipAddress: "10.0.0.50")
        vmLedger.didClientConnect(alunoPainel)
        try? await Task.sleep(nanoseconds: 200_000_000)
        vmLedger.abrirPerfil(clientId: "painel-1")
        assertTest(vmLedger.ledger.resumo(clientId: "painel-1")?.ip == "10.0.0.50", "O ledger do ViewModel recebe a conexão")
        vmLedger.didClientDisconnect(clientId: "painel-1")
        try? await Task.sleep(nanoseconds: 200_000_000)
        assertTest(vmLedger.alunoAberto != nil, "Quando o aluno desconecta, o perfil dele continua aberto")

        // ---- Apps ocultos lembrados entre execuções (RF-19) ----
        let suiteOcultos = "aulacast.teste.ocultos.\(UUID().uuidString)"
        let defaultsOcultos = UserDefaults(suiteName: suiteOcultos)!
        defer { defaultsOcultos.removePersistentDomain(forName: suiteOcultos) }
        let storeOcultos = HiddenAppsStore(defaults: defaultsOcultos)

        assertTest(storeOcultos.carregar().isEmpty, "Store sem dado salvo devolve lista vazia")
        let appsSalvos = [
            HiddenApp(bundleID: "com.b", nome: "zeta"),
            HiddenApp(bundleID: "com.a", nome: "Alfa"),
            HiddenApp(bundleID: "com.c", nome: "beta"),
        ]
        storeOcultos.salvar(appsSalvos)
        let recarregados = storeOcultos.carregar()
        assertTest(Set(recarregados) == Set(appsSalvos), "Store: ida e volta preserva bundleID e nome")
        assertTest(recarregados.map(\.nome) == ["Alfa", "beta", "zeta"], "Store: ordem por nome, sem diferenciar maiúsculas")

        defaultsOcultos.set(Data("isto não é json".utf8), forKey: HiddenAppsStore.chave)
        assertTest(storeOcultos.carregar().isEmpty, "Store: dado corrompido vira lista vazia, sem travar")

        storeOcultos.salvar([HiddenApp(bundleID: "com.salvo", nome: "Salvo")])
        let capturaOcultos = ScreenCaptureService(store: storeOcultos)
        assertTest(capturaOcultos.hiddenBundleIDs == ["com.salvo"], "ScreenCaptureService carrega o conjunto salvo no init")
        assertTest(capturaOcultos.appsOcultos.first?.nome == "Salvo", "ScreenCaptureService lembra o nome do app salvo")
        capturaOcultos.ocultarApp(bundleID: "com.novo", nome: "Novo")
        assertTest(Set(storeOcultos.carregar().map(\.bundleID)) == ["com.salvo", "com.novo"], "Ocultar grava no store, mesmo sem gravação")
        assertTest(storeOcultos.carregar().contains(HiddenApp(bundleID: "com.novo", nome: "Novo")), "Ocultar grava o nome do app")
        capturaOcultos.mostrarApp(bundleID: "com.salvo")
        assertTest(storeOcultos.carregar().map(\.bundleID) == ["com.novo"], "Mostrar remove o app do store")
        capturaOcultos.esquecerTodosOsAppsOcultos()
        assertTest(storeOcultos.carregar().isEmpty && capturaOcultos.hiddenBundleIDs.isEmpty, "esquecerTodos limpa o conjunto e o store")

        let escondidosT: Set<String> = ["com.oculto"]
        assertTest(ScreenCaptureService.deveRefazerFiltro(bundleID: "com.oculto", escondidos: escondidosT, gravandoMonitor: true),
                   "deveRefazerFiltro: app oculto abriu com captura de monitor = sim")
        assertTest(!ScreenCaptureService.deveRefazerFiltro(bundleID: "com.outro", escondidos: escondidosT, gravandoMonitor: true),
                   "deveRefazerFiltro: app não oculto = não")
        assertTest(!ScreenCaptureService.deveRefazerFiltro(bundleID: "com.oculto", escondidos: escondidosT, gravandoMonitor: false),
                   "deveRefazerFiltro: sem captura de monitor (parado ou fonte janela) = não")
        assertTest(!ScreenCaptureService.deveRefazerFiltro(bundleID: nil, escondidos: escondidosT, gravandoMonitor: true),
                   "deveRefazerFiltro: bundle nil = não")
        assertTest(!ScreenCaptureService.deveRefazerFiltro(bundleID: "", escondidos: [""], gravandoMonitor: true),
                   "deveRefazerFiltro: bundle vazio = não")

        await testesMetricasRicas(assertTest)
        await testesPerfilEChamada(assertTest)

        // SUMÁRIO FINAL
        print("\n==========================================")
        print("RESULTADO FINAL DOS TESTES:")
        print("  Passaram: \(placar.passou)")
        print("  Falharam: \(placar.falhou)")
        print("  Modo: \(executarTudo ? "TUDO" : "CORE") | seções puladas: \(placar.puladas.count)")
        placar.puladas.forEach { print("    pulada: \($0)") }
        print("==========================================")
        
        if placar.falhou > 0 {
            exit(1)
        }
    }
}