import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Serviço responsável exclusivamente pela codificação H.264 de quadros de vídeo, via
/// `VideoToolbox` (SRP, OCP, LSP) — substituto em potencial do `MJPEGFrameEncoder`, atrás da
/// mesma interface `VideoEncoderProtocol`.
///
/// Diferença central para o MJPEG: aqui cada quadro pode ser uma predição sobre o anterior
/// (P-frame), não um JPEG independente. Para conteúdo de tela parada/scroll/texto, isso é o
/// que reduz o tráfego de verdade — ver PLANO-COMPRESSAO-DE-VIDEO.md na raiz do repositório.
public final class H264FrameEncoder: VideoEncoderProtocol {
    /// Mantido só para satisfazer `VideoEncoderProtocol` (o ponto de extensão onde
    /// `MainViewModel` pluga o encoder ativo). Este encoder não produz JPEG, então nunca chama
    /// `didReceiveEncodedFrame` — os dados de vídeo saem por `h264OutputReceiver`.
    public weak var outputReceiver: EncodedFrameReceiverProtocol?

    /// Quem recebe os access units H.264 (o empacotador fMP4, em uso normal).
    public weak var h264OutputReceiver: H264AccessUnitReceiverProtocol?

    private let encodingQueue = DispatchQueue(label: "br.com.ifpi.aulacast.h264Queue", qos: .userInitiated)

    private var session: VTCompressionSession?
    private var sessionWidth: Int32 = 0
    private var sessionHeight: Int32 = 0

    /// Quantos quadros já foram entregues ao encoder e ainda não voltaram pelo callback.
    ///
    /// Diferente do MJPEG (uma chamada síncrona), `VTCompressionSessionEncodeFrame` devolve o
    /// controle antes de o quadro estar pronto — o callback chega depois, na fila interna do
    /// VideoToolbox. Sem um teto aqui, uma codificação mais lenta que a captura enfileira
    /// quadros indefinidamente e o atraso cresce sem parar, exatamente o problema que o
    /// `busyLock`/`isEncoding` do MJPEG evita do lado dele.
    private let vooLock = NSLock()
    private var quadrosEmVoo = 0
    /// 2, não 1: o primeiro quadro depois de (re)criar a sessão tem um custo de aquecimento do
    /// encoder de hardware que passa de um período de quadro (medido: um `VTCompressionSession`
    /// recém-criado pode levar bem mais que 33ms — o período de um quadro a 30fps — para
    /// devolver o primeiro resultado). Com o teto em 1, um segundo quadro que chegasse nesse
    /// intervalo era descartado sem nem ser submetido ao encoder, e não só atrasado.
    private static let maxQuadrosEmVoo = 2

    /// Pedido para forçar um quadro-chave no próximo `encode`, feito por quem está prestes a
    /// entregar bytes para um aluno que acabou de entrar (ele não tem nenhum quadro-chave
    /// anterior para decodificar a partir dele).
    private var forcarProximoKeyFrame = false

    /// Quadros por segundo da captura (`ScreenCaptureService.frameRate`). Entra no cálculo da taxa
    /// de bits e do intervalo entre quadros-chave; vale na próxima (re)criação da sessão.
    public var framesPerSecond: Int = 30

    // MARK: - Controle de taxa

    /// Bits por pixel por quadro usados para estimar a taxa média: ~0,04 dá ~2,5 Mbps em
    /// 1080p30, bom para texto/slides com `RealTime`. Ajuste aqui para trocar qualidade por banda.
    static let bitsPorPixelPorQuadro = 0.04
    static let taxaMinimaBps = 1_200_000
    static let taxaMaximaBps = 4_000_000
    /// O teto de picos (quadro-chave) é este múltiplo da média, numa janela de 1 s.
    static let multiplicadorDoTeto = 1.5
    /// Quadro-chave pelo menos a cada tanto tempo, qualquer que seja o fps (uma tela parada
    /// produz poucos quadros, e "60 quadros" viraria minutos).
    static let intervaloMaxEntreChavesSeg = 2.0

    /// Taxa média alvo em bits por segundo, limitada a [`taxaMinimaBps`, `taxaMaximaBps`].
    public static func taxaMediaBps(largura: Int, altura: Int, fps: Int) -> Int {
        let bruta = Double(largura) * Double(altura) * Double(max(1, fps)) * bitsPorPixelPorQuadro
        return Int(min(max(bruta, Double(taxaMinimaBps)), Double(taxaMaximaBps)))
    }

    /// Macroblocos por segundo (limite do nível H.264 4.0: 245 760).
    static func macroblocosPorSegundo(largura: Int, altura: Int, fps: Int) -> Int {
        ((largura + 15) / 16) * ((altura + 15) / 16) * max(1, fps)
    }

    public init() {}

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Chamado por quem entrega fragmentos fMP4 quando uma conexão nova chega: sem isto, o
    /// aluno recém-chegado só veria imagem no próximo quadro-chave "de rotina", que a cada
    /// ~2s (`kVTCompressionPropertyKey_MaxKeyFrameInterval` abaixo) pode demorar demais.
    public func forceNextKeyFrame() {
        vooLock.lock()
        forcarProximoKeyFrame = true
        vooLock.unlock()
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        // Quadros `.idle` (tela parada) e `.suspended` (janela sumiu) chegam sem imagem: nada
        // para codificar, e forçar um pixel buffer inexistente pro VideoToolbox só derrubaria a
        // sessão.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        vooLock.lock()
        if quadrosEmVoo >= Self.maxQuadrosEmVoo {
            vooLock.unlock()
            return
        }
        quadrosEmVoo += 1
        let deveForcarKeyFrame = forcarProximoKeyFrame
        forcarProximoKeyFrame = false
        vooLock.unlock()

        /// O pedido só é "gasto" se o quadro de fato foi submetido; senão volta para a próxima vez.
        let devolverPedido = { if deveForcarKeyFrame { self.forceNextKeyFrame() } }

        let largura = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let altura = Int32(CVPixelBufferGetHeight(pixelBuffer))

        encodingQueue.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessaoValida(largura: largura, altura: altura) else {
                devolverPedido()
                self.marcarQuadroConcluido()
                return
            }

            let tempo = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            var propriedades: [String: Any] = [:]
            if deveForcarKeyFrame {
                propriedades[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
            }

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: tempo,
                duration: .invalid,
                frameProperties: propriedades as CFDictionary,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )

            if status != noErr {
                devolverPedido()
                self.marcarQuadroConcluido()
            }
            // Em caso de sucesso, é o callback (`saidaDoEncoder`) que marca a conclusão —
            // ele chega depois, de forma assíncrona.
        }
    }

    private func marcarQuadroConcluido() {
        vooLock.lock()
        quadrosEmVoo = max(0, quadrosEmVoo - 1)
        vooLock.unlock()
    }

    /// Cria a sessão na primeira chamada, e recria se a resolução mudou ao vivo
    /// (`ScreenCaptureService.resolution`/`frameRate` valem na hora, com a aula no ar).
    private func sessaoValida(largura: Int32, altura: Int32) -> VTCompressionSession? {
        if let session, largura == sessionWidth, altura == sessionHeight {
            return session
        }

        if let session {
            // Entrega o que o encoder ainda segura antes de derrubar a sessão, senão os quadros
            // em voo somem e o contador deles nunca volta a zero.
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        self.session = nil
        vooLock.lock()
        quadrosEmVoo = 0
        vooLock.unlock()

        var novaSessao: VTCompressionSession?
        // `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` pede ao VideoToolbox o
        // codificador de hardware de baixa latência quando disponível (macOS 11+): sem ele, o
        // controle de taxa padrão otimiza para qualidade/arquivo, não para o próximo quadro
        // sair o quanto antes — o que importa numa aula ao vivo, não numa gravação.
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: largura,
            height: altura,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: saidaDoEncoder,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &novaSessao
        )

        guard status == noErr, let novaSessao else { return nil }

        // Baseline: é o perfil com decodificação garantida em qualquer navegador/SO (ver
        // seção 3.4 do PLANO-COMPRESSAO-DE-VIDEO.md) — H.265/AV1 ficam de fora por isso.
        // Nível 4.0 cobre 1080p30; acima disso (ex.: 1080p60) deixa o VideoToolbox escolher.
        let fps = max(1, framesPerSecond)
        let cabeNoNivel40 = Self.macroblocosPorSegundo(largura: Int(largura), altura: Int(altura), fps: fps) <= 245_760
        let nivel = cabeNoNivel40 ? kVTProfileLevel_H264_Baseline_4_0 : kVTProfileLevel_H264_Baseline_AutoLevel
        if VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_ProfileLevel, value: nivel) != noErr {
            VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_ProfileLevel,
                                  value: kVTProfileLevel_H264_Baseline_AutoLevel)
        }
        VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Sem isto o encoder pode reordenar quadros (B-frames), o que exige o decoder — e a
        // rede — segurarem quadros para desembaralhar depois. Numa aula ao vivo isso só
        // adiciona atraso, sem ganho perceptível para conteúdo de tela.
        VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Quadro-chave a cada ~2 s: frequente o bastante para um aluno que troca de aba não
        // ficar muito tempo sem imagem, raro o bastante para não perder o ganho da predição. O
        // limite em segundos é o que vale com a tela parada; o em quadros é só um teto.
        VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                              value: Self.intervaloMaxEntreChavesSeg as CFNumber)
        VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                              value: Int(Self.intervaloMaxEntreChavesSeg) * fps as CFNumber)
        VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        // Controle de taxa: média alvo e teto de picos (DataRateLimits = [bytes, segundos]).
        let taxaMedia = Self.taxaMediaBps(largura: Int(largura), altura: Int(altura), fps: fps)
        VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_AverageBitRate, value: taxaMedia as CFNumber)
        let tetoEmBytes = Int(Double(taxaMedia) * Self.multiplicadorDoTeto / 8)
        VTSessionSetProperty(novaSessao, key: kVTCompressionPropertyKey_DataRateLimits,
                              value: [tetoEmBytes, 1] as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(novaSessao)

        self.session = novaSessao
        sessionWidth = largura
        sessionHeight = altura
        return novaSessao
    }

    fileprivate func processarSaida(sampleBuffer: CMSampleBuffer?, status: OSStatus) {
        defer { marcarQuadroConcluido() }
        // `sampleBuffer == nil` com `status == noErr` é o VideoToolbox dizendo "nada para
        // entregar ainda": mesmo com `AllowFrameReordering=false`, o encoder de baixa latência
        // segura um pequeno buffer de partida (poucos quadros) antes de começar a devolver de
        // verdade — não é erro, e não se repete depois do regime permanente.
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let ehChave = Self.ehQuadroChave(sampleBuffer)
        let dimensoes = CMVideoFormatDescriptionGetDimensions(formatDescription)

        var annexB = Data()
        if ehChave {
            annexB.append(Self.parametrosComoAnnexB(formatDescription))
        }

        guard let corpo = Self.avccParaAnnexB(blockBuffer) else { return }
        annexB.append(corpo)

        let unidade = H264AccessUnit(
            data: annexB,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            isKeyFrame: ehChave,
            width: dimensoes.width,
            height: dimensoes.height
        )
        h264OutputReceiver?.didReceiveAccessUnit(unidade)
    }

    /// Ausência de `kCMSampleAttachmentKey_NotSync` significa quadro-chave — é assim que o
    /// VideoToolbox marca sincronização, em vez de um booleano "é chave" direto.
    private static func ehQuadroChave(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let anexos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let primeiro = anexos.first else {
            return true
        }
        return primeiro[kCMSampleAttachmentKey_NotSync] == nil
    }

    /// SPS e PPS da `CMFormatDescription`, como dois NALs Annex-B (start code + bytes), na
    /// ordem que o `avcC` do empacotador fMP4 espera encontrá-los.
    private static func parametrosComoAnnexB(_ formatDescription: CMFormatDescription) -> Data {
        var resultado = Data()
        for indice in 0..<2 {
            var ponteiro: UnsafePointer<UInt8>?
            var tamanho = 0
            var contagem = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: indice,
                parameterSetPointerOut: &ponteiro,
                parameterSetSizeOut: &tamanho,
                parameterSetCountOut: &contagem,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let ponteiro else { continue }
            resultado.append(contentsOf: [0, 0, 0, 1])
            resultado.append(Data(bytes: ponteiro, count: tamanho))
        }
        return resultado
    }

    /// Converte o `CMBlockBuffer` (NALs prefixados por tamanho de 4 bytes big-endian — o
    /// formato que o VideoToolbox devolve) para Annex-B (NALs prefixados por start code).
    private static func avccParaAnnexB(_ blockBuffer: CMBlockBuffer) -> Data? {
        var comprimentoNoOffset = 0
        var comprimentoTotal = 0
        var ponteiro: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &comprimentoNoOffset,
            totalLengthOut: &comprimentoTotal, dataPointerOut: &ponteiro
        ) == noErr, comprimentoTotal > 0 else { return nil }

        // Bloco contíguo: lê no lugar, e o ponteiro não sai deste escopo. Fragmentado: copia.
        if let ponteiro, comprimentoNoOffset == comprimentoTotal {
            return ponteiro.withMemoryRebound(to: UInt8.self, capacity: comprimentoTotal) {
                converterParaAnnexB(UnsafeBufferPointer(start: $0, count: comprimentoTotal))
            }
        }

        var copia = [UInt8](repeating: 0, count: comprimentoTotal)
        let status = copia.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: comprimentoTotal,
                                       destination: $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        return copia.withUnsafeBufferPointer { converterParaAnnexB($0) }
    }

    private static func converterParaAnnexB(_ bytes: UnsafeBufferPointer<UInt8>) -> Data {
        var resultado = Data()
        var offset = 0
        while offset + 4 <= bytes.count {
            let comprimentoNAL = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard comprimentoNAL > 0, offset + comprimentoNAL <= bytes.count else { break }
            resultado.append(contentsOf: [0, 0, 0, 1])
            resultado.append(UnsafeBufferPointer(rebasing: bytes[offset..<offset + comprimentoNAL]))
            offset += comprimentoNAL
        }
        return resultado
    }
}

/// Callback em C do VideoToolbox: sem contexto de `self` automático, por isso o `refcon`
/// carrega a referência (ver `Unmanaged.passUnretained` na criação da sessão).
private func saidaDoEncoder(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264FrameEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    encoder.processarSaida(sampleBuffer: sampleBuffer, status: status)
}
