import Foundation

/// Fotografia dos contadores do envio de vídeo num instante.
///
/// Os contadores só crescem; as taxas saem da diferença entre duas fotografias
/// (`StreamRates.entre`). "Enviado" quer dizer entregue ao buffer de envio do sistema
/// (`.contentProcessed`), não recebido pelo aluno: é um teto do que o aluno enxerga.
public struct StreamSnapshot: Equatable {
    /// Quadros novos publicados pelo codificador (a tela do professor, em quadros por segundo).
    public var quadrosPublicados: UInt64 = 0
    /// Bytes entregues ao sistema, somando todos os alunos (cabeçalho multipart incluído).
    public var bytesEnviados: UInt64 = 0
    /// Quadros distintos entregues ao sistema por aluno. A repetição do último quadro, feita
    /// por causa do Safari, não conta: é o mesmo quadro de novo.
    /// Chave: número de série do vídeo de cada aluno (nunca reaproveitado, ao contrário de um
    /// endereço de memória, que um aluno novo pode herdar do que saiu).
    public var quadrosPorAluno: [UInt64: UInt64] = [:]

    public init() {}
}

/// Taxas de um intervalo, calculadas entre duas fotografias.
public struct StreamRates: Equatable {
    /// Alunos presentes nas duas fotografias (quem entrou no meio do intervalo fica de fora).
    public let alunos: Int
    public let fpsDaTela: Double
    public let fpsMedioPorAluno: Double
    public let fpsMinimoPorAluno: Double
    public let megabitsPorSegundo: Double

    /// Taxas entre `antes` e `depois`, separadas por `segundos`. `nil` se o intervalo for inválido.
    /// Custo: O(n) no número de alunos.
    public static func entre(_ antes: StreamSnapshot, e depois: StreamSnapshot, segundos: Double) -> StreamRates? {
        guard segundos > 0 else { return nil }

        var soma = 0.0
        var minimo = Double.infinity
        var alunos = 0
        for (aluno, quadrosDepois) in depois.quadrosPorAluno {
            guard let quadrosAntes = antes.quadrosPorAluno[aluno], quadrosDepois >= quadrosAntes else { continue }
            let fps = Double(quadrosDepois - quadrosAntes) / segundos
            soma += fps
            minimo = min(minimo, fps)
            alunos += 1
        }

        return StreamRates(
            alunos: alunos,
            fpsDaTela: Double(crescimento(de: antes.quadrosPublicados, para: depois.quadrosPublicados)) / segundos,
            fpsMedioPorAluno: alunos > 0 ? soma / Double(alunos) : 0,
            fpsMinimoPorAluno: alunos > 0 ? minimo : 0,
            megabitsPorSegundo: Double(crescimento(de: antes.bytesEnviados, para: depois.bytesEnviados)) * 8 / 1_000_000 / segundos
        )
    }

    /// Quanto um contador cresceu. Contador que recuou (reinício) conta como zero, nunca como
    /// uma volta de 2^64, que viraria uma taxa de bilhões.
    private static func crescimento(de antes: UInt64, para depois: UInt64) -> UInt64 {
        depois >= antes ? depois - antes : 0
    }
}
