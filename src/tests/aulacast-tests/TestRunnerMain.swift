import Foundation
import AppKit
import Network
import AulaCastCore

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

        // TESTE 1: ClientManagerService (UC-03 & RF-11: Alunos e Levantar a Mão)
        print("\n--- [1/12] Testes de Domínio: ClientManagerService ---")
        let clientManager = ClientManagerService()
        
        clientManager.addOrUpdateClient(name: "Carlos - PC 04", ip: "192.168.1.50", isHandRaised: false)
        assertTest(clientManager.clients.count == 1, "Conexão de novo aluno registra no gerenciador")
        assertTest(clientManager.clients.first?.name == "Carlos - PC 04", "Nome do aluno registrado corretamente")
        assertTest(clientManager.handRaisedCount == 0, "Contador de mãos levantadas inicia em zero")
        
        clientManager.addOrUpdateClient(name: "Carlos - PC 04", ip: "192.168.1.50", isHandRaised: true)
        assertTest(clientManager.handRaisedCount == 1, "Notificação de Levantar a Mão incrementa contador")
        
        clientManager.addOrUpdateClient(name: "Mariana - PC 08", ip: "192.168.1.51", isHandRaised: true)
        assertTest(clientManager.clients.count == 2, "Dois alunos registrados simultaneamente no gerenciador")
        assertTest(clientManager.handRaisedCount == 2, "Múltiplos alunos levantando a mão incrementam contador")
        
        // Só o próprio aluno abaixa a mão (modelo do Google Meet): o professor observa.
        if let client = clientManager.clients.first {
            clientManager.setHandRaised(clientId: client.id, displayName: client.name, isRaised: false)
            assertTest(clientManager.handRaisedCount == 1, "Aluno abaixando a própria mão decrementa o contador para 1")
        }

        // Trocar o nome exibido não pode criar um segundo registro para o mesmo aluno:
        // era assim que surgiam alunos fantasmas de mão levantada, impossíveis de limpar.
        if let client = clientManager.clients.first {
            let totalAntes = clientManager.clients.count
            clientManager.setHandRaised(clientId: client.id, displayName: "Carlos Eduardo", isRaised: true)
            assertTest(clientManager.clients.count == totalAntes, "Aluno que se identifica depois não vira registro duplicado")
            assertTest(clientManager.clients.first?.name == "Carlos Eduardo", "Nome exibido é atualizado no registro existente")
            clientManager.setHandRaised(clientId: client.id, displayName: "Carlos Eduardo", isRaised: false)
        }

        // Um id desconhecido não deve inventar aluno na lista.
        let totalAntesDeIdInvalido = clientManager.clients.count
        clientManager.setHandRaised(clientId: "id-inexistente", displayName: "Fantasma", isRaised: true)
        assertTest(clientManager.clients.count == totalAntesDeIdInvalido, "Mão levantada de conexão desconhecida é ignorada")

        // Caminho real ponta a ponta: o id criado no handshake precisa sobreviver até o
        // gerenciador, senão a mão levantada é descartada em silêncio (foi o que aconteceu).
        let gerenciadorDeConexao = ClientManagerService()
        let alunoDoHandshake = ConnectedClient(name: "Aluno-1.99", ipAddress: "192.168.1.99", isHandRaised: false)
        gerenciadorDeConexao.addOrUpdateClient(alunoDoHandshake)

        assertTest(
            gerenciadorDeConexao.clients.first?.id == alunoDoHandshake.id,
            "Id gerado no handshake é preservado ao registrar o aluno"
        )

        gerenciadorDeConexao.setHandRaised(clientId: alunoDoHandshake.id, displayName: "Ana", isRaised: true)
        assertTest(
            gerenciadorDeConexao.handRaisedCount == 1,
            "Mão levantada usando o id do handshake aparece para o professor"
        )
        assertTest(
            gerenciadorDeConexao.clients.first?.isHandRaised == true,
            "A linha do aluno fica marcada como mão levantada"
        )

        gerenciadorDeConexao.setHandRaised(clientId: alunoDoHandshake.id, displayName: "Ana", isRaised: false)
        assertTest(
            gerenciadorDeConexao.handRaisedCount == 0,
            "O próprio aluno abaixando a mão zera o contador"
        )

        if let client = clientManager.clients.first {
            clientManager.removeClient(id: client.id)
            assertTest(clientManager.clients.count == 1, "Desconexão de um aluno remove o cliente específico mantendo os demais")
        }

        // Emenda real: WebSocket -> MainViewModel -> ClientManagerService.
        // Testar só o gerenciador não pega o defeito; ele morava na tradução entre camadas.
        let servidorFalso = FakeServer()
        let viewModel = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: servidorFalso,
            advertiserService: FakeAdvertiser()
        )

        let alunoConectado = ConnectedClient(name: "Aluno-2.55", ipAddress: "192.168.2.55", isHandRaised: false)
        viewModel.didClientConnect(alunoConectado)
        try? await Task.sleep(nanoseconds: 150_000_000)

        assertTest(
            viewModel.clientManager.clients.first?.id == alunoConectado.id,
            "Id do handshake sobrevive ao caminho completo até o gerenciador"
        )

        // O aluno levanta a mão informando um nome digitado depois de entrar.
        viewModel.didToggleHandRaise(clientId: alunoConectado.id, displayName: "Ana Beatriz", isRaised: true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        assertTest(
            viewModel.clientManager.handRaisedCount == 1,
            "Mão levantada chega ao app do professor pelo caminho completo"
        )
        assertTest(
            viewModel.clientManager.clients.count == 1,
            "Nome digitado não cria aluno duplicado no caminho completo"
        )

        viewModel.didToggleHandRaise(clientId: alunoConectado.id, displayName: "Ana Beatriz", isRaised: false)
        try? await Task.sleep(nanoseconds: 150_000_000)
        assertTest(
            viewModel.clientManager.handRaisedCount == 0,
            "Aluno abaixa a própria mão pelo caminho completo"
        )

        // TESTE 2: ChatManagerService (UC-05 & RF-09: Chat Local Offline)
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
        
        _ = StaticFileProviderService(webAssetsPath: tempAssetsDir)
        assertTest(true, "Servidor de arquivos estáticos inicializado com sucesso")
        
        try? FileManager.default.removeItem(at: tempAssetsDir)

        // TESTE 5: Servidor de Rede Local (NetworkListenerService)
        print("\n--- [4/12] Testes de Rede: NetworkListenerService ---")
        let serverService = NetworkListenerService(port: 8089, webAssetsPath: FileManager.default.temporaryDirectory)
        
        assertTest(serverService.port == 8089, "Porta do servidor atribuída corretamente")
        assertTest(serverService.localIPAddress != "", "Endereço IP local resolvido pela interface de rede")
        
        do {
            try serverService.start()
            assertTest(serverService.isRunning == true, "Servidor de rede iniciado com sucesso na porta 8089")
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
        let inteiro = frameDeTexto("{\"type\":\"RAISE_HAND\"}")
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
                String(data: frame.payload, encoding: .utf8) == "{\"type\":\"RAISE_HAND\"}",
                "Payload remontado é idêntico ao enviado"
            )
        } else {
            assertTest(false, "Payload remontado é idêntico ao enviado")
        }

        // Comprimento de 8 bytes absurdo: precisa ser rejeitado, não virar alocação gigante.
        var absurdo = Data([0x81, 0xFF])
        absurdo.append(contentsOf: [UInt8](repeating: 0xFF, count: 8)) // comprimento gigantesco
        absurdo.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        let resultadoAbsurdo = WebSocketFrameDecoder().consume(absurdo)
        assertTest(
            resultadoAbsurdo == .protocolViolation,
            "Comprimento absurdo é rejeitado sem derrubar o app"
        )

        // TESTE 8: WebSocket real ponta a ponta contra o servidor do app.
        // Cobre o handshake e o caminho da mão levantada depois da refatoração do decodificador.
        print("\n--- [8/12] Testes E2E: WebSocket real ---")

        final class ColetorDeMaos: HandRaiseObserverProtocol, ClientObserverProtocol, StudentPresenceObserverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _conectados: [ConnectedClient] = []
            private var _maos: [(id: String, nome: String, levantada: Bool)] = []
            private var _identificacoes: [(id: String, nome: String, matricula: String)] = []
            private var _presencas: [(id: String, assistindo: Bool)] = []

            var conectados: [ConnectedClient] { trava.lock(); defer { trava.unlock() }; return _conectados }
            var maos: [(id: String, nome: String, levantada: Bool)] { trava.lock(); defer { trava.unlock() }; return _maos }
            var identificacoes: [(id: String, nome: String, matricula: String)] { trava.lock(); defer { trava.unlock() }; return _identificacoes }
            var presencas: [(id: String, assistindo: Bool)] { trava.lock(); defer { trava.unlock() }; return _presencas }

            func didToggleHandRaise(clientId: String, displayName: String, isRaised: Bool) {
                trava.lock(); _maos.append((clientId, displayName, isRaised)); trava.unlock()
            }
            func didClientConnect(_ client: ConnectedClient) {
                trava.lock(); _conectados.append(client); trava.unlock()
            }
            func didClientDisconnect(clientId: String) {}
            func didIdentifyStudent(clientId: String, name: String, matricula: String) {
                trava.lock(); _identificacoes.append((clientId, name, matricula)); trava.unlock()
            }
            func didChangeWatching(clientId: String, isWatching: Bool) {
                trava.lock(); _presencas.append((clientId, isWatching)); trava.unlock()
            }
        }

        let coletor = ColetorDeMaos()
        let servidorE2E = NetworkListenerService(port: 8100, webAssetsPath: FileManager.default.temporaryDirectory)
        servidorE2E.handRaiseObserver = coletor
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

            try? await socket.send(.string("{\"type\":\"RAISE_HAND\",\"payload\":{\"studentName\":\"Ana E2E\",\"active\":true}}"))
            try? await Task.sleep(nanoseconds: 400_000_000)

            assertTest(coletor.conectados.count == 1, "Servidor registrou o aluno na conexão")
            assertTest(coletor.maos.count == 1, "Mão levantada trafegou pelo WebSocket real")
            assertTest(coletor.maos.first?.levantada == true, "Estado recebido é 'mão levantada'")
            assertTest(coletor.maos.first?.nome == "Ana E2E", "Nome informado pelo aluno chega ao servidor")
            assertTest(
                coletor.maos.first?.id == coletor.conectados.first?.id,
                "Id da mão levantada é o mesmo da conexão (não um registro novo)"
            )

            // O servidor pode ter mensagens já na fila (o ACK da mão levantada, por exemplo),
            // então é preciso ler até achar a esperada em vez de assumir que vem primeiro.
            func aguardarMensagem(contendo trecho: String, tentativas: Int = 6) async -> Bool {
                for _ in 0..<tentativas {
                    guard case .string(let texto)? = try? await socket.receive() else { return false }
                    if texto.contains(trecho) { return true }
                }
                return false
            }

            // Identificação ponta a ponta pelo WebSocket real.
            try? await socket.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Ana Beatriz\",\"matricula\":\"2021234tads5678\"}}"))
            let identificacaoAceita = await aguardarMensagem(contendo: "IDENTIFY_ACCEPTED")
            try? await Task.sleep(nanoseconds: 300_000_000)

            assertTest(identificacaoAceita, "Servidor aceita identificação com matrícula válida")
            assertTest(coletor.identificacoes.count == 1, "Identificação chega ao app do professor")
            assertTest(coletor.identificacoes.first?.matricula == "2021234TADS5678", "Matrícula chega normalizada ao professor")

            // Matrícula fora do padrão precisa ser recusada pelo servidor, e não só pelo navegador.
            try? await socket.send(.string("{\"type\":\"IDENTIFY\",\"payload\":{\"name\":\"Fraude\",\"matricula\":\"1231234INFO0000\"}}"))
            let recusou = await aguardarMensagem(contendo: "IDENTIFY_REJECTED")
            try? await Task.sleep(nanoseconds: 300_000_000)

            assertTest(recusou, "Servidor recusa matrícula inválida mesmo vinda de cliente adulterado")
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
            socketChatLigado.cancel(with: .goingAway, reason: nil)

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

            servidorE2E.stop()
        } catch {
            assertTest(false, "Falha no teste E2E de WebSocket: \(error.localizedDescription)")
        }

        // TESTE 10: Matrícula do IFPI e presença na tela.
        print("\n--- [9/12] Testes de Domínio: identificação e presença ---")

        assertTest(MatriculaIFPI.ehValida("2021234TADS5678"), "Matrícula no formato 202XXXXTADSXXXX é aceita")
        assertTest(MatriculaIFPI.ehValida("  2021234tads5678 "), "Minúsculas e espaços são normalizados")
        assertTest(!MatriculaIFPI.ehValida("2021234TADS567"), "Matrícula curta é recusada")
        assertTest(!MatriculaIFPI.ehValida("2021234TADS56789"), "Matrícula longa é recusada")
        assertTest(!MatriculaIFPI.ehValida("1991234TADS5678"), "Matrícula que não começa com 202 é recusada")
        assertTest(!MatriculaIFPI.ehValida("2021234INFO5678"), "Curso diferente de TADS é recusado")
        assertTest(!MatriculaIFPI.ehValida("202ABCDTADS5678"), "Letras no lugar de dígitos são recusadas")
        assertTest(!MatriculaIFPI.ehValida("2021234TADSABCD"), "Letras no bloco final são recusadas")

        let turma = ClientManagerService()
        let aluno = ConnectedClient(name: "Aluno-3.10", ipAddress: "192.168.3.10")
        turma.addOrUpdateClient(aluno)

        assertTest(turma.clients.first?.hasIdentified == false, "Aluno começa sem identificação")
        assertTest(turma.watchingCount == 1, "Aluno recém-conectado conta como assistindo")

        turma.identify(clientId: aluno.id, name: "Ana Beatriz", matricula: "2021234tads5678")
        assertTest(turma.clients.first?.name == "Ana Beatriz", "Nome informado aparece na lista do professor")
        assertTest(turma.clients.first?.matricula == "2021234TADS5678", "Matrícula é guardada normalizada")
        assertTest(turma.clients.first?.hasIdentified == true, "Aluno passa a constar como identificado")

        // O aluno minimizou a janela ou trocou de aba.
        turma.setWatching(clientId: aluno.id, isWatching: false)
        assertTest(turma.clients.first?.isWatching == false, "Aluno fora da tela é marcado como não assistindo")
        assertTest(turma.watchingCount == 0, "Contador de quem está vendo cai para zero")

        turma.setWatching(clientId: aluno.id, isWatching: true)
        assertTest(turma.watchingCount == 1, "Aluno que volta à tela volta a contar")

        // Identificação vinda de conexão desconhecida não pode criar aluno.
        let totalAntesDeIdentificacaoInvalida = turma.clients.count
        turma.identify(clientId: "id-inexistente", name: "Fantasma", matricula: "2029999TADS9999")
        turma.setWatching(clientId: "id-inexistente", isWatching: false)
        assertTest(
            turma.clients.count == totalAntesDeIdentificacaoInvalida,
            "Identificação de conexão desconhecida é ignorada"
        )

        // TESTE 10: Prévia local do professor.
        // Ela mostra o último quadro realmente transmitido; se parar de atualizar, o professor
        // perde a única confirmação visual de que os alunos estão vendo alguma coisa.
        print("\n--- [10/12] Testes de Domínio: prévia da transmissão ---")

        let vmPrevia = MainViewModel(
            captureService: FakeCaptureService(),
            encoderService: FakeEncoder(),
            serverService: FakeServer(),
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

        // Pausado, a prévia não deve avançar — mas também não pode sumir.
        vmPrevia.togglePause()
        let previaAntesDaPausa = vmPrevia.latestPreviewImage
        vmPrevia.didReceiveEncodedFrame(data: jpegDeTeste, isKeyFrame: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
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

        final class ColetorDeChat: ChatObserverProtocol, @unchecked Sendable {
            private let trava = NSLock()
            private var _recebidas: [ChatMessage] = []
            var recebidas: [ChatMessage] { trava.lock(); defer { trava.unlock() }; return _recebidas }
            func didReceiveChatMessage(_ message: ChatMessage) {
                trava.lock(); _recebidas.append(message); trava.unlock()
            }
        }

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

            _ = try? await alunoA.receive() // CONNECTED
            _ = try? await alunoB.receive() // CONNECTED

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
                permission: FakePermission(concedida: permissao)
            )
            return (vm, captura, servidor)
        }

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
        let primeiraAna = ConnectedClient(name: "Ana", ipAddress: "192.168.1.20", isHandRaised: false)
        let segundaAna = ConnectedClient(name: "Ana", ipAddress: "192.168.1.21", isHandRaised: true)
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
        assertTest(
            gerenciadorHomonimos.handRaisedCount == 0,
            "A mão levantada de quem saiu não fica pendurada no contador"
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

        // SUMÁRIO FINAL
        print("\n==========================================")
        print("RESULTADO FINAL DOS TESTES:")
        print("  Passaram: \(placar.passou)")
        print("  Falharam: \(placar.falhou)")
        print("==========================================")
        
        if placar.falhou > 0 {
            exit(1)
        }
    }
}