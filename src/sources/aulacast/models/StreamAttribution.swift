import Foundation

/// O que o servidor mediu de UMA conexão de vídeo num intervalo.
public struct MedidaDeConexao: Equatable {
    public let ip: String
    public let fps: Double
    public let mbps: Double
    public let quadros: Int
    public let estouros: Int

    public init(ip: String, fps: Double, mbps: Double, quadros: Int, estouros: Int) {
        self.ip = ip; self.fps = fps; self.mbps = mbps; self.quadros = quadros; self.estouros = estouros
    }
}

/// O que o servidor mediu para um aluno (todas as conexões de vídeo do IP dele).
public struct MedidaDoServidor: Equatable {
    public let fps: Double
    public let mbps: Double
    public let quadros: Int
    public let estouros: Int
    /// Dois ou mais alunos usam o mesmo IP (NAT, roteador): os números são do IP, não de um aluno.
    public let compartilhado: Bool

    public init(fps: Double, mbps: Double, quadros: Int, estouros: Int, compartilhado: Bool) {
        self.fps = fps; self.mbps = mbps; self.quadros = quadros; self.estouros = estouros; self.compartilhado = compartilhado
    }
}

public enum StreamAttribution {
    /// Medida por conexão entre duas fotografias. Só conexões presentes nas duas. O(n).
    public static func medidas(_ antes: StreamSnapshot, e depois: StreamSnapshot, segundos: Double) -> [MedidaDeConexao] {
        guard segundos > 0 else { return [] }
        return depois.quadrosPorAluno.compactMap { serie, quadrosDepois in
            guard let quadrosAntes = antes.quadrosPorAluno[serie], quadrosDepois >= quadrosAntes,
                  let ip = depois.ipPorAluno[serie] else { return nil }
            let dq = Int(quadrosDepois - quadrosAntes)
            let bytes = (depois.bytesPorAluno[serie] ?? 0) &- (antes.bytesPorAluno[serie] ?? 0)
            let est = (depois.estourosPorAluno[serie] ?? 0) &- (antes.estourosPorAluno[serie] ?? 0)
            return MedidaDeConexao(ip: ip, fps: Double(dq) / segundos,
                                   mbps: Double(bytes) * 8 / 1_000_000 / segundos,
                                   quadros: dq, estouros: Int(truncatingIfNeeded: est))
        }
    }

    /// Liga as conexões de vídeo aos alunos pelo IP (função pura). Por IP: `mbps`, `quadros` e
    /// `estouros` somam (um aluno com duas abas gasta as duas), `fps` é o maior. Alunos sem
    /// conexão de vídeo não aparecem no resultado. O(alunos + conexões).
    public static func atribuir(alunos: [String: String], conexoes: [MedidaDeConexao]) -> [String: MedidaDoServidor] {
        var porIP: [String: MedidaDeConexao] = [:]
        for c in conexoes {
            if let a = porIP[c.ip] {
                porIP[c.ip] = MedidaDeConexao(ip: c.ip, fps: max(a.fps, c.fps), mbps: a.mbps + c.mbps,
                                              quadros: a.quadros + c.quadros, estouros: a.estouros + c.estouros)
            } else {
                porIP[c.ip] = c
            }
        }
        var alunosPorIP: [String: Int] = [:]
        for ip in alunos.values { alunosPorIP[ip, default: 0] += 1 }
        var saida: [String: MedidaDoServidor] = [:]
        for (id, ip) in alunos {
            guard let m = porIP[ip] else { continue }
            saida[id] = MedidaDoServidor(fps: m.fps, mbps: m.mbps, quadros: m.quadros, estouros: m.estouros,
                                         compartilhado: (alunosPorIP[ip] ?? 0) > 1)
        }
        return saida
    }
}
