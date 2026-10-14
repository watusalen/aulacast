import { STREAM_RETRY_BASE_MS, STREAM_RETRY_MAX_MS } from './config.js';

/**
 * Perfil Baseline: é o único com decodificação garantida em qualquer navegador/SO (ver
 * PLANO-COMPRESSAO-DE-VIDEO.md, seção 3.4). `avc1.42E01E` é Baseline, nível 3.0.
 */
const CODEC_H264_BASELINE = 'video/mp4; codecs="avc1.42E01E"';

/**
 * Depois de tantas quedas seguidas da conexão HTTP de `/stream.mp4`, desiste e cai para o
 * MJPEG em vez de continuar tentando: mesma ideia do teto de espera do `StreamWatchdog`
 * (`STREAM_RETRY_MAX_MS`), mas aqui um número de tentativas, não um tempo — a rede pode
 * estar simplesmente incapaz de sustentar vídeo com predição entre quadros (um fragmento
 * perdido quebra a decodificação até o próximo quadro-chave, ver `MP4StreamerService`), e
 * nesse caso insistir não ajuda: o MJPEG, com quadros independentes, tolera melhor.
 */
const MAX_TENTATIVAS_DE_RECONEXAO = 5;

/**
 * Suporte real via feature detection — nunca por sniffing de user-agent.
 *
 * `ManagedMediaSource` é a variante do Safari em iOS/iPadOS 17.1+ (o `MediaSource` clássico
 * nunca existiu lá). Em qualquer outro navegador com suporte, é o `MediaSource` normal.
 */
export function mediaSourceSuportado(janela = typeof window !== 'undefined' ? window : undefined) {
  if (!janela) return false;
  const Impl = janela.MediaSource || janela.ManagedMediaSource;
  if (!Impl || typeof Impl.isTypeSupported !== 'function') return false;
  try {
    return Impl.isTypeSupported(CODEC_H264_BASELINE);
  } catch (_) {
    return false;
  }
}

/**
 * Player de `/stream.mp4` (H.264 em fMP4) via `MediaSource`/`ManagedMediaSource`.
 *
 * Não sabe nada sobre o `StreamWatchdog` nem sobre o `<img>` do MJPEG — de propósito: os
 * dois convivem sem se acoplar (ver PLANO-COMPRESSAO-DE-VIDEO.md, seção 8.4). Este player só
 * cuida do próprio `<video>`, escondido por padrão, e mostrado quando o primeiro quadro
 * decodificável entra no `SourceBuffer`. Se em algum ponto isto não for possível — sem
 * suporte, uma falha de inicialização, ou a conexão cair repetidas vezes — ele se esconde de
 * volta e chama `onFallback`, e quem instanciou decide o que fazer (na prática, deixar o
 * `<img>` do MJPEG, que nunca para de funcionar, aparecer por baixo).
 */
export class VideoStreamPlayer {
  /**
   * @param {HTMLVideoElement} videoElement
   * @param {{ onFallback?: (motivo: string) => void,
   *           onEstado?: (estado: 'ao-vivo' | 'reconectando') => void,
   *           janela?: Window, fetchImpl?: Function, urlImpl?: typeof URL }} opcoes
   *   `janela`/`fetchImpl`/`urlImpl` existem para os testes injetarem dublês (sem DOM real).
   */
  constructor(videoElement, opcoes = {}) {
    this.video = videoElement;
    this.onFallback = opcoes.onFallback || (() => {});
    this.onEstado = opcoes.onEstado || (() => {});
    this.janela = opcoes.janela || (typeof window !== 'undefined' ? window : undefined);
    this.fetchImpl = opcoes.fetchImpl || (this.janela && this.janela.fetch ? this.janela.fetch.bind(this.janela) : undefined);
    this.urlImpl = opcoes.urlImpl || (this.janela ? this.janela.URL : undefined);

    this.streamUrl = this.janela
      ? `${this.janela.location.protocol}//${this.janela.location.host}/stream.mp4`
      : '/stream.mp4';

    this.mediaSource = null;
    this.sourceBuffer = null;
    this.filaDePedacos = [];
    this.leitor = null;
    this.abortController = null;
    this.tentativas = 0;
    this.retryTimer = null;
    /** Pedido de transmitir está de pé — cai para `false` só em `stop()` ou desistência. */
    this.querTransmitir = false;
    /** Já mostrou o `<video>` nesta tentativa de conexão (primeiro `appendBuffer` com sucesso). */
    this.mostrouVideo = false;
    /** Já avisou `onFallback` nesta tentativa — evita avisar duas vezes por uma só desistência. */
    this.emFallback = false;

    // Mesma classe do <img> do MJPEG (`.stream`, `display: none` por padrão em styles.css):
    // dá o mesmo tamanho/posição de graça, e ligar `.active` (como o `<img>` já faz) é o que
    // mostra a imagem — não o atributo `hidden`, que uma regra de classe mais específica
    // ignoraria. Os dois elementos convivem no mesmo `.video-wrap`: o `<video>` vem depois do
    // `<img>` no HTML, então com `.active` nos dois ele fica por cima, sem precisar esconder
    // o MJPEG por baixo.
    this.video.classList.remove('active');
  }

  /** Tenta iniciar a transmissão H.264. Sem suporte de MSE, cai para o MJPEG na hora. */
  start() {
    if (this.querTransmitir) return;
    // Um novo `start()` (ex.: nova aula) pode tentar de novo e, se falhar de novo, avisar de
    // novo — só a queda DENTRO da mesma tentativa não deve avisar duas vezes.
    this.emFallback = false;
    if (!mediaSourceSuportado(this.janela) || !this.fetchImpl) {
      this.cairParaFallback('sem suporte a MediaSource/fetch neste navegador');
      return;
    }
    this.querTransmitir = true;
    this.tentativas = 0;
    this.conectar();
  }

  /** Encerra de propósito (aula parada/terminada) — não é uma queda para tentar de novo. */
  stop() {
    this.querTransmitir = false;
    this.limparTimer();
    this.encerrarConexaoAtual();
    this.esconderVideo();
  }

  conectar() {
    if (!this.querTransmitir) return;
    this.encerrarConexaoAtual();
    try {
      this.iniciarMediaSource();
    } catch (erro) {
      this.aoFalhar(`erro ao iniciar MediaSource: ${erro}`);
    }
  }

  iniciarMediaSource() {
    const janela = this.janela;
    const ManagedImpl = janela && janela.ManagedMediaSource;
    const usaManaged = janela && !janela.MediaSource && Boolean(ManagedImpl);
    // `ManagedMediaSource` (Safari em iOS/iPadOS 17.1+) exige o <video> já no DOM e este
    // atributo antes de criar o objeto — diferente do `MediaSource` clássico, que aceita ser
    // criado a qualquer momento. Ver a documentação da WebKit sobre Managed Media Source.
    if (usaManaged) {
      this.video.disableRemotePlayback = true;
    }
    const Impl = (janela && janela.MediaSource) || ManagedImpl;
    this.mediaSource = new Impl();
    this.mediaSource.addEventListener('sourceopen', () => this.aoAbrirFonte(), { once: true });
    this.mediaSource.addEventListener('sourceended', () => this.aoQuedaDeConexao('sourceended'));
    this.mediaSource.addEventListener('sourceclose', () => this.aoQuedaDeConexao('sourceclose'));

    const criarUrl = this.urlImpl && this.urlImpl.createObjectURL
      ? this.urlImpl.createObjectURL.bind(this.urlImpl)
      : null;
    if (!criarUrl) {
      this.aoFalhar('URL.createObjectURL indisponível');
      return;
    }
    this.objectUrlAtual = criarUrl(this.mediaSource);
    this.video.src = this.objectUrlAtual;

    // Só a primeira vez: erros depois de mostrar vídeo já são tratados como queda de conexão
    // pela leitura do stream, não por este evento (que também dispara ao trocar/limpar o src).
    if (!this.ouvindoErroDoVideo) {
      this.ouvindoErroDoVideo = true;
      this.video.addEventListener('error', () => {
        if (this.querTransmitir && !this.mostrouVideo) {
          this.aoFalhar('erro do elemento <video> antes do primeiro quadro');
        }
      });
    }
  }

  aoAbrirFonte() {
    if (!this.querTransmitir) return;
    try {
      this.sourceBuffer = this.mediaSource.addSourceBuffer(CODEC_H264_BASELINE);
    } catch (erro) {
      this.aoFalhar(`addSourceBuffer falhou: ${erro}`);
      return;
    }
    this.sourceBuffer.addEventListener('updateend', () => this.escoarFila());
    this.sourceBuffer.addEventListener('error', () => this.aoQuedaDeConexao('erro do SourceBuffer'));
    this.buscarStream();
  }

  async buscarStream() {
    this.abortController = typeof AbortController !== 'undefined' ? new AbortController() : null;
    let resposta;
    try {
      resposta = await this.fetchImpl(this.streamUrl, {
        signal: this.abortController ? this.abortController.signal : undefined,
        cache: 'no-store'
      });
    } catch (erro) {
      if (!this.querTransmitir) return; // abortado de propósito por stop()/conectar() de novo
      this.aoQuedaDeConexao(`fetch falhou: ${erro}`);
      return;
    }
    if (!this.querTransmitir) return;
    if (!resposta || !resposta.ok || !resposta.body) {
      this.aoQuedaDeConexao(`resposta HTTP inválida (status ${resposta && resposta.status})`);
      return;
    }
    this.leitor = resposta.body.getReader();
    // Conexão de verdade estabelecida: a próxima queda volta a contar tentativas do zero.
    this.tentativas = 0;
    this.bombearLeitura();
  }

  async bombearLeitura() {
    const leitor = this.leitor;
    try {
      while (this.querTransmitir && this.leitor === leitor) {
        const { value, done } = await leitor.read();
        if (!this.querTransmitir || this.leitor !== leitor) return;
        if (done) {
          this.aoQuedaDeConexao('conexão encerrada pelo servidor');
          return;
        }
        if (value && value.byteLength) {
          this.filaDePedacos.push(value);
          this.escoarFila();
        }
      }
    } catch (erro) {
      if (!this.querTransmitir || this.leitor !== leitor) return;
      this.aoQuedaDeConexao(`leitura falhou: ${erro}`);
    }
  }

  /**
   * Manda o próximo pedaço da fila para o `SourceBuffer`, só se ele não estiver ocupado
   * (`updating`) — chamar `appendBuffer` nesse meio tempo lança `InvalidStateError`. O que
   * chega enquanto ele processa fica na fila e sai no `updateend`.
   */
  escoarFila() {
    if (!this.sourceBuffer || this.sourceBuffer.updating || this.filaDePedacos.length === 0) return;
    const proximo = this.filaDePedacos.shift();
    try {
      this.sourceBuffer.appendBuffer(proximo);
    } catch (erro) {
      this.aoQuedaDeConexao(`appendBuffer falhou: ${erro}`);
      return;
    }
    if (!this.mostrouVideo) {
      this.mostrouVideo = true;
      this.video.classList.add('active');
      this.onEstado('ao-vivo');
    }
  }

  /**
   * A conexão HTTP caiu no meio (oscilação de rede, servidor reiniciado, ou o servidor
   * derrubando de propósito por mudança de resolução ao vivo — ver `MP4StreamerService`):
   * tenta de novo com espera crescente antes de desistir de vez.
   */
  aoQuedaDeConexao(motivo) {
    if (!this.querTransmitir) return;
    this.encerrarConexaoAtual();
    this.tentativas += 1;
    if (this.tentativas > MAX_TENTATIVAS_DE_RECONEXAO) {
      this.aoFalhar(`desistiu depois de ${this.tentativas - 1} tentativa(s) (${motivo})`);
      return;
    }
    this.onEstado('reconectando');
    const espera = Math.min(
      STREAM_RETRY_BASE_MS * Math.pow(2, this.tentativas - 1),
      STREAM_RETRY_MAX_MS
    );
    this.limparTimer();
    this.retryTimer = setTimeout(() => this.conectar(), espera);
  }

  /** Falha que não compensa tentar de novo sozinho: volta para o MJPEG. */
  aoFalhar(motivo) {
    this.cairParaFallback(motivo);
  }

  cairParaFallback(motivo) {
    const primeiraVezNestaTentativa = !this.emFallback;
    this.emFallback = true;
    this.querTransmitir = false;
    this.limparTimer();
    this.encerrarConexaoAtual();
    this.esconderVideo();
    if (primeiraVezNestaTentativa) this.onFallback(motivo);
  }

  esconderVideo() {
    this.video.classList.remove('active');
    this.mostrouVideo = false;
  }

  limparTimer() {
    if (this.retryTimer) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }

  encerrarConexaoAtual() {
    if (this.abortController) {
      this.abortController.abort();
      this.abortController = null;
    }
    this.leitor = null;
    this.filaDePedacos = [];
    if (this.sourceBuffer && this.mediaSource) {
      try { this.mediaSource.removeSourceBuffer(this.sourceBuffer); } catch (_) { /* já não pertence à fonte */ }
    }
    this.sourceBuffer = null;
    if (this.mediaSource && this.mediaSource.readyState === 'open') {
      try { this.mediaSource.endOfStream(); } catch (_) { /* nada a encerrar */ }
    }
    this.mediaSource = null;
    if (this.objectUrlAtual && this.urlImpl && this.urlImpl.revokeObjectURL) {
      this.urlImpl.revokeObjectURL(this.objectUrlAtual);
    }
    this.objectUrlAtual = null;
    if (this.video.getAttribute('src')) {
      this.video.removeAttribute('src');
    }
  }
}
