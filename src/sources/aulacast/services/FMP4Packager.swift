import Foundation
import CoreMedia

/// Empacotador ISO-BMFF (fMP4 fragmentado) mínimo: uma única faixa de vídeo H.264, sem áudio,
/// sem seek, sem DVR — só o suficiente para o `SourceBuffer` de um `<video>` com
/// `MediaSource`/`ManagedMediaSource` aceitar via `appendBuffer` (SRP, OCP).
///
/// Segue o padrão "moov vazio" (`stts`/`stsc`/`stsz`/`stco` com `entry_count = 0`, tudo que
/// importa vem depois em `moof`/`mdat`) — o mesmo que o `ffmpeg` usa com
/// `-movflags frag_keyframe+empty_moov` para fMP4 de baixa latência.
public final class FMP4Packager: H264AccessUnitReceiverProtocol {
    public weak var outputReceiver: FMP4FragmentReceiverProtocol?

    /// Escala de tempo da faixa de mídia. 90 kHz é a escala clássica de vídeo em MPEG — dá
    /// resolução de sobra para qualquer fps que o AulaCast ofereça (15/30/45) sem frações.
    private static let mediaTimescale: Int32 = 90_000
    private static let trackID: UInt32 = 1

    /// Período nominal de um quadro (30 fps: o maior valor típico entre os oferecidos). A duração
    /// de cada amostra é o intervalo real desde o quadro anterior, limitado a
    /// `maxPeriodosPorAmostra` períodos: depois de uma tela parada (que não produz quadros) o
    /// próximo quadro não pode ganhar dezenas de segundos de duração, senão a imagem congela e o
    /// atraso se acumula no player.
    private static let duracaoNominal = UInt32(mediaTimescale / 30)
    private static let maxPeriodosPorAmostra: Int64 = 2

    /// Protege todo o estado: chamado pela thread do VideoToolbox e por `MainViewModel` (`reset()`).
    private let lock = NSLock()

    private var sps: Data?
    private var pps: Data?
    private var largura = 0
    private var altura = 0

    private var sequenceNumber: UInt32 = 0
    private var baseMediaDecodeTime: UInt64 = 0
    private var tempoApresentadoAnterior: CMTime?

    public init() {}

    /// Esquece SPS, resolução e relógio: a próxima sessão emite um segmento de inicialização novo.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        sps = nil
        pps = nil
        largura = 0
        altura = 0
        reiniciarRelogio()
    }

    private func reiniciarRelogio() {
        sequenceNumber = 0
        baseMediaDecodeTime = 0
        tempoApresentadoAnterior = nil
    }

    public func didReceiveAccessUnit(_ unit: H264AccessUnit) {
        let nals = Self.dividirEmNALs(unit.data)

        lock.lock()
        defer { lock.unlock() }

        if unit.isKeyFrame {
            var novoSPS: Data?
            var novoPPS: Data?
            for nal in nals {
                guard let primeiro = nal.first else { continue }
                switch primeiro & 0x1F {
                case 7: novoSPS = nal
                case 8: novoPPS = nal
                default: break
                }
            }
            guard let novoSPS, let novoPPS else { return }

            // Novo `avcC`/`moov` só quando algo que ele descreve muda (SPS, PPS ou resolução) —
            // não a cada quadro-chave "de rotina".
            let precisaNovoInit = sps != novoSPS || pps != novoPPS
                || largura != Int(unit.width) || altura != Int(unit.height)
            sps = novoSPS
            pps = novoPPS
            largura = Int(unit.width)
            altura = Int(unit.height)

            if precisaNovoInit {
                reiniciarRelogio()
                outputReceiver?.didReceiveFragment(montarInitSegment(), isInitSegment: true, isKeyFrame: true)
            }
        }

        // Sem SPS/PPS ainda não há `avcC` válido para montar nada — só acontece antes do
        // primeiro quadro-chave, que é sempre o primeiro quadro da sessão.
        guard sps != nil, pps != nil else { return }

        let amostra = Self.montarAmostra(nals: nals)
        guard !amostra.isEmpty else { return }

        let duracao = duracaoDoQuadro(unit.presentationTime)
        let fragmento = montarFragmento(amostra: amostra, duracao: duracao, isKeyFrame: unit.isKeyFrame)
        outputReceiver?.didReceiveFragment(fragmento, isInitSegment: false, isKeyFrame: unit.isKeyFrame)

        sequenceNumber &+= 1
        baseMediaDecodeTime &+= UInt64(duracao)
        tempoApresentadoAnterior = unit.presentationTime
    }

    /// Duração desta amostra: o intervalo desde o quadro anterior, entre 1 tick e
    /// `maxPeriodosPorAmostra` períodos nominais. Sem quadro anterior (ou tempo inválido), o
    /// período nominal. O `baseMediaDecodeTime` avança pela mesma duração, então a linha do
    /// tempo do `SourceBuffer` continua contígua mesmo depois de uma pausa na captura.
    private func duracaoDoQuadro(_ tempo: CMTime) -> UInt32 {
        guard let anterior = tempoApresentadoAnterior, tempo.isNumeric, anterior.isNumeric else {
            return Self.duracaoNominal
        }
        let delta = CMTimeSubtract(tempo, anterior)
        let escalado = CMTimeConvertScale(delta, timescale: Self.mediaTimescale, method: .default)
        let teto = Int64(Self.duracaoNominal) * Self.maxPeriodosPorAmostra
        return UInt32(clamping: min(max(1, escalado.value), teto))
    }

    // MARK: - NALs

    private static let startCode = Data([0, 0, 0, 1])

    /// Separa o Annex-B em NALs individuais (sem o start code). Assume start codes de 4 bytes
    /// em todo lugar — é sempre o que `H264FrameEncoder` produz, então não há necessidade de
    /// também reconhecer o start code de 3 bytes que outras fontes usam.
    private static func dividirEmNALs(_ data: Data) -> [Data] {
        var inicios: [Data.Index] = []
        var buscaAPartirDe = data.startIndex
        while let intervalo = data.range(of: startCode, in: buscaAPartirDe..<data.endIndex) {
            inicios.append(intervalo.upperBound)
            buscaAPartirDe = intervalo.upperBound
        }

        var resultado: [Data] = []
        for (indice, inicio) in inicios.enumerated() {
            let fim: Data.Index
            if indice + 1 < inicios.count {
                fim = data.index(inicios[indice + 1], offsetBy: -startCode.count)
            } else {
                fim = data.endIndex
            }
            if fim > inicio {
                resultado.append(data.subdata(in: inicio..<fim))
            }
        }
        return resultado
    }

    /// NALs de imagem (tudo menos SPS/PPS, tipos 7 e 8 — esses só existem no `avcC`, fora de
    /// banda), no formato tamanho-prefixado (4 bytes big-endian) que o `mdat` exige.
    private static func montarAmostra(nals: [Data]) -> Data {
        var resultado = Data()
        for nal in nals {
            guard let primeiro = nal.first else { continue }
            let tipo = primeiro & 0x1F
            guard tipo != 7, tipo != 8 else { continue }
            resultado.append(u32(UInt32(nal.count)))
            resultado.append(nal)
        }
        return resultado
    }

    // MARK: - Caixas ISO-BMFF

    private static func box(_ tipo: String, _ conteudo: Data) -> Data {
        var caixa = u32(UInt32(conteudo.count + 8))
        caixa.append(tipo.data(using: .ascii)!)
        caixa.append(conteudo)
        return caixa
    }

    private static func fullBoxHeader(version: UInt8, flags: UInt32) -> Data {
        Data([version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)])
    }

    private static func u16(_ valor: UInt16) -> Data { var v = valor.bigEndian; return Data(bytes: &v, count: 2) }
    private static func u32(_ valor: UInt32) -> Data { var v = valor.bigEndian; return Data(bytes: &v, count: 4) }
    private static func u64(_ valor: UInt64) -> Data { var v = valor.bigEndian; return Data(bytes: &v, count: 8) }
    private static func i32(_ valor: Int32) -> Data { var v = valor.bigEndian; return Data(bytes: &v, count: 4) }

    private static let matrizIdentidade: [Int32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

    private static func montarFtyp() -> Data {
        var conteudo = "isom".data(using: .ascii)!
        conteudo.append(u32(512))
        for marca in ["isom", "iso5", "avc1", "mp41"] {
            conteudo.append(marca.data(using: .ascii)!)
        }
        return box("ftyp", conteudo)
    }

    private func montarAvcC() -> Data {
        guard let sps, let pps, sps.count >= 4 else { return Data() }
        var conteudo = Data([1, sps[sps.startIndex + 1], sps[sps.startIndex + 2], sps[sps.startIndex + 3]])
        conteudo.append(0xFF) // reserved(6)=1 + lengthSizeMinusOne(2)=3 (comprimento de 4 bytes)
        conteudo.append(0xE1) // reserved(3)=1 + numOfSequenceParameterSets(5)=1
        conteudo.append(Self.u16(UInt16(sps.count)))
        conteudo.append(sps)
        conteudo.append(1) // numOfPictureParameterSets
        conteudo.append(Self.u16(UInt16(pps.count)))
        conteudo.append(pps)
        return Self.box("avcC", conteudo)
    }

    private func montarAvc1() -> Data {
        var conteudo = Data(repeating: 0, count: 6) // reserved
        conteudo.append(Self.u16(1)) // data_reference_index
        conteudo.append(Self.u16(0)) // pre_defined
        conteudo.append(Self.u16(0)) // reserved
        conteudo.append(Data(repeating: 0, count: 12)) // pre_defined (3x u32)
        conteudo.append(Self.u16(UInt16(largura)))
        conteudo.append(Self.u16(UInt16(altura)))
        conteudo.append(Self.u32(0x0048_0000)) // horizresolution: 72 dpi
        conteudo.append(Self.u32(0x0048_0000)) // vertresolution: 72 dpi
        conteudo.append(Self.u32(0)) // reserved
        conteudo.append(Self.u16(1)) // frame_count
        conteudo.append(Data(repeating: 0, count: 32)) // compressorname (vazio)
        conteudo.append(Self.u16(0x0018)) // depth
        conteudo.append(Data([0xFF, 0xFF])) // pre_defined = -1
        conteudo.append(montarAvcC())
        return Self.box("avc1", conteudo)
    }

    private func montarStsd() -> Data {
        var conteudo = Self.fullBoxHeader(version: 0, flags: 0)
        conteudo.append(Self.u32(1)) // entry_count
        conteudo.append(montarAvc1())
        return Self.box("stsd", conteudo)
    }

    private static func montarTabelaVazia(_ tipo: String) -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 0)
        conteudo.append(u32(0)) // entry_count
        return box(tipo, conteudo)
    }

    private static func montarStsz() -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 0)
        conteudo.append(u32(0)) // sample_size (0 = tamanhos variam, mas a tabela está vazia)
        conteudo.append(u32(0)) // sample_count
        return box("stsz", conteudo)
    }

    private func montarStbl() -> Data {
        var conteudo = montarStsd()
        conteudo.append(Self.montarTabelaVazia("stts"))
        conteudo.append(Self.montarTabelaVazia("stsc"))
        conteudo.append(Self.montarStsz())
        conteudo.append(Self.montarTabelaVazia("stco"))
        return Self.box("stbl", conteudo)
    }

    private static func montarVmhd() -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 1)
        conteudo.append(u16(0)) // graphicsmode
        conteudo.append(Data(repeating: 0, count: 6)) // opcolor
        return box("vmhd", conteudo)
    }

    private static func montarDinf() -> Data {
        let urlBox = box("url ", fullBoxHeader(version: 0, flags: 1)) // flags=1: referência autocontida
        var drefConteudo = fullBoxHeader(version: 0, flags: 0)
        drefConteudo.append(u32(1))
        drefConteudo.append(urlBox)
        return box("dinf", box("dref", drefConteudo))
    }

    private func montarMinf() -> Data {
        var conteudo = Self.montarVmhd()
        conteudo.append(Self.montarDinf())
        conteudo.append(montarStbl())
        return Self.box("minf", conteudo)
    }

    private static func montarHdlr() -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 0)
        conteudo.append(u32(0)) // pre_defined
        conteudo.append("vide".data(using: .ascii)!)
        conteudo.append(Data(repeating: 0, count: 12)) // reserved
        conteudo.append("AulaCastVideoHandler\0".data(using: .ascii)!)
        return box("hdlr", conteudo)
    }

    private static func montarMdhd() -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 0)
        conteudo.append(u32(0)) // creation_time
        conteudo.append(u32(0)) // modification_time
        conteudo.append(u32(UInt32(mediaTimescale)))
        conteudo.append(u32(0)) // duration: desconhecida (fragmentado)
        conteudo.append(u16(0x55C4)) // language "und"
        conteudo.append(u16(0)) // pre_defined
        return box("mdhd", conteudo)
    }

    private func montarMdia() -> Data {
        var conteudo = Self.montarMdhd()
        conteudo.append(Self.montarHdlr())
        conteudo.append(montarMinf())
        return Self.box("mdia", conteudo)
    }

    private func montarTkhd() -> Data {
        var conteudo = Self.fullBoxHeader(version: 0, flags: 0x000007) // enabled + in_movie + in_preview
        conteudo.append(Self.u32(0)) // creation_time
        conteudo.append(Self.u32(0)) // modification_time
        conteudo.append(Self.u32(Self.trackID))
        conteudo.append(Self.u32(0)) // reserved
        conteudo.append(Self.u32(0)) // duration
        conteudo.append(Data(repeating: 0, count: 8)) // reserved
        conteudo.append(Self.u16(0)) // layer
        conteudo.append(Self.u16(0)) // alternate_group
        conteudo.append(Self.u16(0)) // volume (faixa de vídeo)
        conteudo.append(Self.u16(0)) // reserved
        for valor in Self.matrizIdentidade { conteudo.append(Self.u32(UInt32(bitPattern: valor))) }
        conteudo.append(Self.u32(UInt32(largura) << 16))
        conteudo.append(Self.u32(UInt32(altura) << 16))
        return Self.box("tkhd", conteudo)
    }

    private func montarTrak() -> Data {
        var conteudo = montarTkhd()
        conteudo.append(montarMdia())
        return Self.box("trak", conteudo)
    }

    private static func montarMvhd() -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 0)
        conteudo.append(u32(0)) // creation_time
        conteudo.append(u32(0)) // modification_time
        conteudo.append(u32(1000)) // timescale do filme (independente do de mídia)
        conteudo.append(u32(0)) // duration: desconhecida
        conteudo.append(u32(0x0001_0000)) // rate 1.0
        conteudo.append(u16(0x0100)) // volume 1.0
        conteudo.append(u16(0)) // reserved
        conteudo.append(Data(repeating: 0, count: 8)) // reserved
        for valor in matrizIdentidade { conteudo.append(u32(UInt32(bitPattern: valor))) }
        conteudo.append(Data(repeating: 0, count: 24)) // pre_defined
        conteudo.append(u32(2)) // next_track_ID
        return box("mvhd", conteudo)
    }

    private static func montarMvex() -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 0)
        conteudo.append(u32(trackID))
        conteudo.append(u32(1)) // default_sample_description_index
        conteudo.append(u32(0)) // default_sample_duration
        conteudo.append(u32(0)) // default_sample_size
        conteudo.append(u32(0)) // default_sample_flags
        return box("mvex", box("trex", conteudo))
    }

    private func montarInitSegment() -> Data {
        var conteudoMoov = Self.montarMvhd()
        conteudoMoov.append(montarTrak())
        conteudoMoov.append(Self.montarMvex())

        var dados = Self.montarFtyp()
        dados.append(Self.box("moov", conteudoMoov))
        return dados
    }

    // MARK: - Fragmento (moof + mdat)

    private static func montarMfhd(sequencia: UInt32) -> Data {
        var conteudo = fullBoxHeader(version: 0, flags: 0)
        conteudo.append(u32(sequencia))
        return box("mfhd", conteudo)
    }

    private static func montarTfhd() -> Data {
        let flags: UInt32 = 0x02_0000 // default-base-is-moof
        var conteudo = fullBoxHeader(version: 0, flags: flags)
        conteudo.append(u32(trackID))
        return box("tfhd", conteudo)
    }

    private static func montarTfdt(baseMediaDecodeTime: UInt64) -> Data {
        var conteudo = fullBoxHeader(version: 1, flags: 0)
        conteudo.append(u64(baseMediaDecodeTime))
        return box("tfdt", conteudo)
    }

    /// Valores usados amplamente por outros muxers fMP4 (ex.: mp4box.js, dash.js) para os
    /// bits de `sample_depends_on`/`sample_is_non_sync_sample` de `trun`: quadro-chave não
    /// depende de nenhum outro (`depends_on = 2`, `non_sync = 0`); os demais dependem
    /// (`depends_on = 1`, `non_sync = 1`).
    private static func sampleFlags(isKeyFrame: Bool) -> UInt32 {
        isKeyFrame ? 0x0200_0000 : 0x0101_0000
    }

    private static func montarTrun(duracao: UInt32, tamanho: UInt32, isKeyFrame: Bool, dataOffset: Int32) -> Data {
        let flags: UInt32 = 0x000001 | 0x000100 | 0x000200 | 0x000400
        var conteudo = fullBoxHeader(version: 0, flags: flags)
        conteudo.append(u32(1)) // sample_count
        conteudo.append(i32(dataOffset))
        conteudo.append(u32(duracao))
        conteudo.append(u32(tamanho))
        conteudo.append(u32(sampleFlags(isKeyFrame: isKeyFrame)))
        return box("trun", conteudo)
    }

    /// Monta com um `data_offset` provisório, mede o tamanho de fato do `moof` e remonta com o
    /// valor certo — evita um número mágico hardcoded que quebraria em silêncio se alguma caixa
    /// aqui em cima mudar de tamanho no futuro.
    private func montarFragmento(amostra: Data, duracao: UInt32, isKeyFrame: Bool) -> Data {
        let sequencia = sequenceNumber &+ 1

        func montarMoof(dataOffset: Int32) -> Data {
            var traf = Self.montarTfhd()
            traf.append(Self.montarTfdt(baseMediaDecodeTime: baseMediaDecodeTime))
            traf.append(Self.montarTrun(duracao: duracao, tamanho: UInt32(amostra.count),
                                         isKeyFrame: isKeyFrame, dataOffset: dataOffset))
            var conteudo = Self.montarMfhd(sequencia: sequencia)
            conteudo.append(Self.box("traf", traf))
            return Self.box("moof", conteudo)
        }

        let tamanhoDoMoof = montarMoof(dataOffset: 0).count
        let moof = montarMoof(dataOffset: Int32(tamanhoDoMoof) + 8) // +8: cabeçalho do mdat

        var mdat = Self.u32(UInt32(amostra.count + 8))
        mdat.append("mdat".data(using: .ascii)!)
        mdat.append(amostra)

        var fragmento = moof
        fragmento.append(mdat)
        return fragmento
    }
}
