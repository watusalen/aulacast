/// As métricas por aluno (METRICS, METRICS_TABLE e o arquivo da sessão) só existem em build de
/// depuração ou com `-Xswiftc -DMETRICAS_DEBUG` (ver `scripts/build-app.sh`). Num build normal
/// o servidor não avisa o navegador, que fica quieto, e ignora qualquer METRICS recebida.
public enum MetricasDebug {
    public static let ativo: Bool = {
        #if DEBUG || METRICAS_DEBUG
        return true
        #else
        return false
        #endif
    }()
}
