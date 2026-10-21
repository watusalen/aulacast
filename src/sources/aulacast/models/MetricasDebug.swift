/// Coleta de métricas por aluno (METRICS/ENV/EVENT, arquivo da sessão, linha `[Métricas]`) é
/// PERMANENTE e existe em todo build (ADR-006). Só a EXIBIÇÃO no console do navegador do aluno
/// (METRICS_TABLE, DEBUG_INFO, painel de depuração) é temporária: exige build de depuração ou
/// `-Xswiftc -DMETRICAS_DEBUG` (ver `scripts/build-app.sh`). Os testes trocam o valor por instância.
public enum MetricasDebug {
    public static let consoleAtivo: Bool = {
        #if DEBUG || METRICAS_DEBUG
        return true
        #else
        return false
        #endif
    }()
}
