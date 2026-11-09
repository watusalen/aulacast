import Foundation

/// Um nome que a pessoa usou na aula (ADR-005). `viaIP`: o nome foi ligado a uma pessoa
/// reconhecida pelo IP, e não pelo nome (o IP casou, mas o nome informado era outro).
public struct NomeUsado: Equatable {
    public let nome: String
    public let primeiraVez: Date
    public let ultimaVez: Date
    public let viaIP: Bool
    /// É o nome atual da pessoa (o mais recente).
    public let atual: Bool
    var chave: String
}

/// Uma conexão da pessoa (um navegador aberto): nome usado, entrada, saída (nil = conectada agora)
/// e o palpite de navegador e aparelho (nil enquanto o `ENV` não chegou ou se for desconhecido).
public struct ConexaoDaPessoa: Equatable {
    public let id: String
    public let nome: String
    public let entrouAs: Date
    public let saiuAs: Date?
    public let descricao: String?
    public var ativa: Bool { saiuAs == nil }
}

/// Números de um aluno para o painel do professor (RF-20).
public struct AttendanceSummary: Equatable {
    /// Identidade estável da pessoa na sessão: sobrevive a reconexões e a troca de nome.
    public let pessoaId: String
    public let nome: String?
    /// Nomes usados, do primeiro ao último (no máximo `AttendanceLedger.maxNomes`).
    public let nomes: [NomeUsado]
    /// Uma entrada por conexão, da mais antiga à mais nova (no máximo `AttendanceLedger.maxNomes`).
    public let conexoes: [ConexaoDaPessoa]
    /// Última desconexão (nil se nunca saiu) e se há conexão aberta agora.
    public let ultimaSaidaAs: Date?
    public let conectada: Bool
    public let ip: String
    public let entrouAs: Date
    /// Tempo com pelo menos uma conexão aberta, só enquanto a aula corre.
    public let naAula: TimeInterval
    /// Tempo com conexão aberta E aba visível e em foco.
    public let aVista: TimeInterval
    public let saidas: Int
    public let maiorTrecho: TimeInterval
    public let desconexoes: Int

    /// À vista / na aula, de 0 a 1 (0 quando ainda não há tempo de aula).
    public var fracaoAVista: Double { naAula > 0 ? min(1, aVista / naAula) : 0 }
}

/// Texto curto de uma duração: "42 s", "42 min 10 s", "1 h 02 min".
public func formatarDuracao(_ segundos: TimeInterval) -> String {
    let total = Int(max(0, segundos))
    if total < 60 { return "\(total) s" }
    if total < 3600 { return "\(total / 60) min \(String(format: "%02d", total % 60)) s" }
    return "\(total / 3600) h \(String(format: "%02d", total % 3600 / 60)) min"
}

/// Tempo de cada aluno na aula, sem guardar histórico (O(1) de memória por pessoa, O(1) por evento).
///
/// Um relógio global só avança enquanto a aula corre (transmitindo e sem pausa). Cada pessoa
/// guarda o valor do relógio na última atualização; o que passou desde então é somado ao
/// estado dela (conectada? à vista?) só quando algo muda ou quando o resumo é pedido.
/// Identidade (ADR-005): mesmo IP é sempre a mesma pessoa; senão, o nome normalizado junta
/// com quem não tem conexão aberta; com conexão aberta em outro IP são homônimos.
public final class AttendanceLedger {
    public static let maxNomes = 20

    private final class Pessoa {
        let id = UUID().uuidString
        var ip = ""
        var nomes: [NomeUsado] = []
        var registros: [ConexaoDaPessoa] = []
        var ultimaSaida: Date?
        var nome: String?
        var ips: Set<String> = []
        var chaves: Set<String> = []
        var entrouAs: Date
        var naAula: TimeInterval = 0
        var aVista: TimeInterval = 0
        var saidas = 0
        var maior: TimeInterval = 0
        var trecho: TimeInterval = 0
        var desconexoes = 0
        var conexoes = 0
        var visiveis = 0
        var jaConectou = false
        var relogio: TimeInterval = 0

        init(entrouAs: Date) { self.entrouAs = entrouAs }

        func somar(ate agora: TimeInterval) {
            let delta = max(0, agora - relogio)
            relogio = agora
            if conexoes > 0 { naAula += delta }
            if visiveis > 0 {
                aVista += delta
                trecho += delta
                maior = max(maior, trecho)
            }
        }

        /// Atualiza ou acrescenta o nome. Teto de `maxNomes`: o mais antigo sai. O(maxNomes).
        func registrarNome(_ nome: String, chave: String, em instante: Date, viaIP: Bool, ultima: Date? = nil) {
            let fim = ultima ?? instante
            if let i = nomes.firstIndex(where: { $0.chave == chave }) {
                let n = nomes[i]
                nomes[i] = NomeUsado(nome: n.nome, primeiraVez: min(n.primeiraVez, instante), ultimaVez: max(n.ultimaVez, fim),
                                     viaIP: n.viaIP, atual: false, chave: chave)
            } else {
                nomes.append(NomeUsado(nome: nome, primeiraVez: instante, ultimaVez: fim, viaIP: viaIP, atual: false, chave: chave))
                nomes.sort { $0.primeiraVez < $1.primeiraVez }
                if nomes.count > AttendanceLedger.maxNomes { nomes.removeFirst() }
            }
        }

        /// Cria ou atualiza o registro da conexão. Teto de `maxNomes`: sai a mais antiga já encerrada
        /// (ou a mais antiga, se todas estão ativas). O(maxNomes).
        func registrarConexao(_ id: String, nome: String, entrouAs: Date) {
            if let i = registros.firstIndex(where: { $0.id == id }) {
                let r = registros[i]
                registros[i] = ConexaoDaPessoa(id: id, nome: nome, entrouAs: r.entrouAs, saiuAs: r.saiuAs, descricao: r.descricao)
                return
            }
            registros.append(ConexaoDaPessoa(id: id, nome: nome, entrouAs: entrouAs, saiuAs: nil, descricao: nil))
            registros.sort { $0.entrouAs < $1.entrouAs }
            if registros.count > AttendanceLedger.maxNomes {
                registros.remove(at: registros.firstIndex(where: { !$0.ativa }) ?? 0)
            }
        }

        func alterarConexao(_ id: String, saiuAs: Date? = nil, descricao: String? = nil) {
            guard let i = registros.firstIndex(where: { $0.id == id }) else { return }
            let r = registros[i]
            registros[i] = ConexaoDaPessoa(id: id, nome: r.nome, entrouAs: r.entrouAs,
                                           saiuAs: saiuAs ?? r.saiuAs, descricao: descricao ?? r.descricao)
        }

        /// Chamado depois de `visiveis` mudar: sem aba visível o trecho contínuo termina.
        func perdeuAVista() {
            saidas += 1
            trecho = 0
        }
    }

    private struct Conexao {
        var pessoa: Pessoa
        let ip: String
        var visivel: Bool
        let desde: Date
    }

    private let lock = NSLock()
    private let agoraDoSistema: () -> Date
    private var corre = false
    private var acumulado: TimeInterval = 0
    private var ultimoInstante: Date
    private var conexoes: [String: Conexao] = [:]
    private var porIP: [String: Pessoa] = [:]
    private var porNome: [String: Pessoa] = [:]
    private var pessoas: [ObjectIdentifier: Pessoa] = [:]
    /// Id estável -> pessoa. Ids de pessoas fundidas continuam apontando para quem ficou.
    private var porId: [String: Pessoa] = [:]

    public init(clock: @escaping () -> Date = Date.init) {
        agoraDoSistema = clock
        ultimoInstante = clock()
    }

    // MARK: Eventos

    public func setAccruing(_ ligado: Bool, at: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        avancar(at ?? agoraDoSistema())
        corre = ligado
    }

    /// Nova aula: zera os números, mantém quem está conectado e esquece quem saiu.
    public func reset(at: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        acumulado = 0
        ultimoInstante = at ?? agoraDoSistema()
        pessoas = pessoas.filter { $0.value.conexoes > 0 }
        porIP = porIP.filter { pessoas[ObjectIdentifier($0.value)] != nil }
        porNome = porNome.filter { pessoas[ObjectIdentifier($0.value)] != nil }
        porId = porId.filter { pessoas[ObjectIdentifier($0.value)] != nil }
        for pessoa in pessoas.values {
            pessoa.registros.removeAll { !$0.ativa }
            pessoa.naAula = 0; pessoa.aVista = 0; pessoa.saidas = 0
            pessoa.maior = 0; pessoa.trecho = 0; pessoa.desconexoes = 0
            pessoa.relogio = 0
            pessoa.ips = pessoa.ips.filter { porIP[$0] === pessoa }
            pessoa.chaves = pessoa.chaves.filter { porNome[$0] === pessoa }
        }
    }

    public func connected(clientId: String, ip: String, visible: Bool = true, at: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let instante = at ?? agoraDoSistema()
        avancar(instante)
        if conexoes[clientId] != nil { return }
        let pessoa = porIP[ip] ?? novaPessoa(ip: ip, entrouAs: instante)
        pessoa.somar(ate: acumulado)
        if pessoa.conexoes == 0, pessoa.jaConectou { pessoa.desconexoes += 1 }
        pessoa.jaConectou = true
        pessoa.ip = ip
        pessoa.conexoes += 1
        if visible { pessoa.visiveis += 1 }
        conexoes[clientId] = Conexao(pessoa: pessoa, ip: ip, visivel: visible, desde: instante)
    }

    public func identified(clientId: String, name: String, at: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        avancar(at ?? agoraDoSistema())
        guard let conexao = conexoes[clientId], !name.isEmpty else { return }
        let instante = at ?? agoraDoSistema()
        let chave = Self.normalizar(name)
        var pessoa = conexao.pessoa
        // Pessoa já reconhecida (pelo IP) com outro nome: o nome novo entra "via IP".
        let viaIP = pessoa.nome.map { Self.normalizar($0) != chave } ?? false
        if let outra = porNome[chave], outra !== pessoa, outra.conexoes == 0 {
            pessoa = fundir(pessoa, em: outra)
        }
        pessoa.registrarNome(name, chave: chave, em: instante, viaIP: viaIP)
        pessoa.registrarConexao(clientId, nome: name, entrouAs: conexao.desde)
        pessoa.nome = name
        pessoa.chaves.insert(chave)
        // Homônimo conectado de outro IP: quem chegou antes continua dono do nome.
        if porNome[chave] == nil || porNome[chave] === pessoa { porNome[chave] = pessoa }
    }

    public func visibility(clientId: String, visible: Bool, at: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        avancar(at ?? agoraDoSistema())
        guard var conexao = conexoes[clientId], conexao.visivel != visible else { return }
        let pessoa = conexao.pessoa
        pessoa.somar(ate: acumulado)
        conexao.visivel = visible
        conexoes[clientId] = conexao
        if visible {
            pessoa.visiveis += 1
        } else {
            pessoa.visiveis -= 1
            if pessoa.visiveis == 0 { pessoa.perdeuAVista() }
        }
    }

    public func disconnected(clientId: String, at: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        avancar(at ?? agoraDoSistema())
        guard let conexao = conexoes.removeValue(forKey: clientId) else { return }
        let pessoa = conexao.pessoa
        pessoa.somar(ate: acumulado)
        pessoa.conexoes -= 1
        pessoa.ultimaSaida = at ?? agoraDoSistema()
        pessoa.alterarConexao(clientId, saiuAs: pessoa.ultimaSaida)
        if conexao.visivel {
            pessoa.visiveis -= 1
            if pessoa.visiveis == 0 { pessoa.perdeuAVista() }
        }
    }

    // MARK: Consulta

    public func resumo(clientId: String, agora: Date? = nil) -> AttendanceSummary? {
        lock.lock(); defer { lock.unlock() }
        guard let conexao = conexoes[clientId] else { return nil }
        return resumo(de: conexao.pessoa, ip: conexao.ip, agora: agora)
    }

    /// Funciona também depois que a pessoa saiu (o painel de perfil continua abrindo).
    public func resumo(pessoaId: String, agora: Date? = nil) -> AttendanceSummary? {
        lock.lock(); defer { lock.unlock() }
        guard let pessoa = porId[pessoaId] else { return nil }
        return resumo(de: pessoa, ip: pessoa.ip, agora: agora)
    }

    /// O `ENV` chegou: guarda o palpite de navegador e aparelho na conexão (nada muda se for desconhecido).
    public func environment(clientId: String, userAgent: String) {
        lock.lock(); defer { lock.unlock() }
        guard let conexao = conexoes[clientId],
              let texto = NavegadorDetectado.descrever(userAgent: userAgent) else { return }
        conexao.pessoa.alterarConexao(clientId, descricao: texto)
    }

    public func pessoaId(clientId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return conexoes[clientId]?.pessoa.id
    }

    /// Busca em TODOS os nomes que alguém usou na aula, sem diferenciar caixa, acento nem espaços.
    /// Homônimo: quem chegou antes continua dono do nome. O(1).
    public func pessoaId(nome: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return porNome[Self.normalizar(nome)]?.id
    }

    /// Só quem tem nome (identificado), do que entrou primeiro ao último. O(n log n).
    public func todos(agora: Date? = nil) -> [AttendanceSummary] {
        lock.lock(); defer { lock.unlock() }
        return pessoas.values.filter { $0.nome != nil }
            .sorted { ($0.entrouAs, $0.id) < ($1.entrouAs, $1.id) }
            .map { resumo(de: $0, ip: $0.ip, agora: agora) }
    }

    private func resumo(de pessoa: Pessoa, ip: String, agora: Date?) -> AttendanceSummary {
        let delta = max(0, relogio(em: agora ?? agoraDoSistema()) - pessoa.relogio)
        let vista = pessoa.visiveis > 0 ? delta : 0
        let atual = pessoa.nome.map(Self.normalizar)
        return AttendanceSummary(
            pessoaId: pessoa.id,
            nome: pessoa.nome,
            nomes: pessoa.nomes.map { NomeUsado(nome: $0.nome, primeiraVez: $0.primeiraVez, ultimaVez: $0.ultimaVez, viaIP: $0.viaIP, atual: $0.chave == atual, chave: $0.chave) },
            conexoes: pessoa.registros,
            ultimaSaidaAs: pessoa.ultimaSaida,
            conectada: pessoa.conexoes > 0,
            ip: ip,
            entrouAs: pessoa.entrouAs,
            naAula: pessoa.naAula + (pessoa.conexoes > 0 ? delta : 0),
            aVista: pessoa.aVista + vista,
            saidas: pessoa.saidas,
            maiorTrecho: max(pessoa.maior, pessoa.trecho + vista),
            desconexoes: pessoa.desconexoes
        )
    }

    /// Tempos de cada pessoa com nome, para o `fim` do arquivo de métricas (chave: nome).
    /// Mesma conta do `resumo`. O(n) nas pessoas.
    public func temposPorNome(agora: Date? = nil) -> [String: [String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let relogioAgora = relogio(em: agora ?? agoraDoSistema())
        var saida: [String: [String: Any]] = [:]
        for pessoa in pessoas.values {
            guard let nome = pessoa.nome else { continue }
            let delta = max(0, relogioAgora - pessoa.relogio)
            let vista = pessoa.visiveis > 0 ? delta : 0
            let naAula = pessoa.naAula + (pessoa.conexoes > 0 ? delta : 0)
            let aVista = pessoa.aVista + vista
            saida[nome] = [
                "naAulaS": naAula.rounded(), "aVistaS": aVista.rounded(),
                "aVistaPct": naAula > 0 ? (min(1, aVista / naAula) * 1000).rounded() / 10 : 0,
                "saidas": pessoa.saidas, "maiorTrechoS": max(pessoa.maior, pessoa.trecho + vista).rounded()
            ]
        }
        return saida
    }

    // MARK: Internos

    private func relogio(em instante: Date) -> TimeInterval {
        acumulado + (corre ? max(0, instante.timeIntervalSince(ultimoInstante)) : 0)
    }

    private func avancar(_ instante: Date) {
        acumulado = relogio(em: instante)
        ultimoInstante = max(ultimoInstante, instante)
    }

    private func novaPessoa(ip: String, entrouAs: Date) -> Pessoa {
        let pessoa = Pessoa(entrouAs: entrouAs)
        pessoa.relogio = acumulado
        pessoa.ips.insert(ip)
        porId[pessoa.id] = pessoa
        porIP[ip] = pessoa
        pessoas[ObjectIdentifier(pessoa)] = pessoa
        return pessoa
    }

    /// Junta `origem` (a pessoa criada pela conexão nova) em `destino` (quem saiu e voltou com outro IP).
    private func fundir(_ origem: Pessoa, em destino: Pessoa) -> Pessoa {
        origem.somar(ate: acumulado)
        destino.somar(ate: acumulado)
        destino.naAula += origem.naAula
        destino.aVista += origem.aVista
        destino.saidas += origem.saidas
        destino.maior = max(destino.maior, origem.maior)
        destino.trecho = origem.trecho
        destino.desconexoes += origem.desconexoes + 1
        destino.conexoes += origem.conexoes
        destino.visiveis += origem.visiveis
        destino.entrouAs = min(destino.entrouAs, origem.entrouAs)
        for ip in origem.ips { porIP[ip] = destino; destino.ips.insert(ip) }
        for chave in origem.chaves where porNome[chave] === origem { porNome[chave] = destino }
        for (id, conexao) in conexoes where conexao.pessoa === origem { conexoes[id]?.pessoa = destino }
        for r in origem.registros where !destino.registros.contains(where: { $0.id == r.id }) {
            destino.registros.append(r)
        }
        destino.registros.sort { $0.entrouAs < $1.entrouAs }
        if destino.registros.count > Self.maxNomes {
            destino.registros.removeFirst(destino.registros.count - Self.maxNomes)
        }
        for n in origem.nomes { destino.registrarNome(n.nome, chave: n.chave, em: n.primeiraVez, viaIP: n.viaIP, ultima: n.ultimaVez) }
        if let saida = origem.ultimaSaida { destino.ultimaSaida = max(destino.ultimaSaida ?? saida, saida) }
        for (id, p) in porId where p === origem { porId[id] = destino }
        pessoas[ObjectIdentifier(origem)] = nil
        return destino
    }

    /// Minúsculas, sem acentos e sem espaços repetidos nem nas pontas.
    static func normalizar(_ nome: String) -> String {
        nome.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
