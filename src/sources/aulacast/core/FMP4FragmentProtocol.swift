import Foundation

/// Quem recebe os bytes de vídeo já prontos para escrever na conexão HTTP.
///
/// `isInitSegment` é verdadeiro só quando `data` é o segmento de inicialização (`ftyp`+`moov`)
/// que o `SourceBuffer` do navegador exige antes de qualquer fragmento; do contrário é um
/// fragmento `moof`+`mdat`, tipicamente um por quadro. `isKeyFrame` (sempre `true` para o
/// init segment) diz se este ponto do fluxo é seguro para uma conexão nova/re-sincronizando
/// começar a decodificar a partir dele — um fragmento com um P-frame sozinho não é.
public protocol FMP4FragmentReceiverProtocol: AnyObject {
    func didReceiveFragment(_ data: Data, isInitSegment: Bool, isKeyFrame: Bool)
}
