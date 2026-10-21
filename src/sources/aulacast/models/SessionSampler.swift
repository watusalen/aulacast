import Foundation
import CoreWLAN
import Darwin

/// Mede CPU e memória do próprio app (só para o arquivo de métricas de depuração).
/// CPU: variação do tempo de CPU (`getrusage`) sobre o tempo de relógio decorrido desde a
/// chamada anterior; 100 = um núcleo inteiro. Memória: `phys_footprint`, o que o Monitor de
/// Atividade mostra. Seguro entre threads.
public final class ProcessSampler {
    private var cpuAnterior: Double
    private var relogioAnterior: DispatchTime
    private let trava = NSLock()

    public init() {
        cpuAnterior = Self.segundosDeCPU()
        relogioAnterior = .now()
    }

    /// `cpuPct` e `memMB`, ambos >= 0.
    public func amostrar() -> (cpuPct: Double, memMB: Double) {
        trava.lock(); defer { trava.unlock() }
        let agora = DispatchTime.now()
        let cpu = Self.segundosDeCPU()
        let decorrido = Double(agora.uptimeNanoseconds &- relogioAnterior.uptimeNanoseconds) / 1_000_000_000
        let pct = decorrido > 0 ? max(0, (cpu - cpuAnterior) / decorrido * 100) : 0
        cpuAnterior = cpu
        relogioAnterior = agora
        return (pct, Self.memoriaMB())
    }

    public static func segundosDeCPU() -> Double {
        var uso = rusage()
        guard getrusage(RUSAGE_SELF, &uso) == 0 else { return 0 }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(uso.ru_utime) + s(uso.ru_stime)
    }

    public static func memoriaMB() -> Double {
        var info = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &contagem)
            }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Fatos do Mac e da rede, lidos uma vez no início e (Wi-Fi) a cada amostra.
public enum SessionEnvironment {
    /// Wi-Fi do Mac do professor, ou `nil` fora do Wi-Fi. O CoreWLAN pode devolver zeros sem
    /// a permissão de localização: tudo zerado também vira `nil`, para não plotar um 0 falso.
    public static func wifi() -> [String: Any]? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let rssi = i.rssiValue(), ruido = i.noiseMeasurement(), taxa = i.transmitRate()
        guard rssi != 0 || taxa > 0 else { return nil }
        return ["rssi": rssi, "ruido": ruido, "taxaTxMbps": taxa, "canal": i.wlanChannel()?.channelNumber ?? 0]
    }

    /// Modelo do Mac (ex.: "Mac14,2"), via `sysctl hw.model`.
    public static func modeloDoMac() -> String {
        var tamanho = 0
        guard sysctlbyname("hw.model", nil, &tamanho, nil, 0) == 0, tamanho > 0 else { return "desconhecido" }
        var bytes = [CChar](repeating: 0, count: tamanho)
        guard sysctlbyname("hw.model", &bytes, &tamanho, nil, 0) == 0 else { return "desconhecido" }
        return String(cString: bytes)
    }

    /// Interfaces ativas com IPv4 (nome e endereço), sem loopback.
    public static func interfacesAtivas() -> [[String: String]] {
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primeira = lista else { return [] }
        defer { freeifaddrs(lista) }
        var saida: [[String: String]] = []
        for p in sequence(first: primeira, next: { $0.pointee.ifa_next }) {
            let f = p.pointee
            guard let a = f.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  Int32(f.ifa_flags) & IFF_UP != 0, Int32(f.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            saida.append(["nome": String(cString: f.ifa_name), "ip": String(cString: host)])
        }
        return saida
    }

    /// Fatos do `inicio` que não dependem do app.
    public static func fatosDoMac() -> [String: Any] {
        [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "modeloMac": modeloDoMac(),
            "nucleos": ProcessInfo.processInfo.activeProcessorCount,
            "interfaces": interfacesAtivas()
        ]
    }
}
