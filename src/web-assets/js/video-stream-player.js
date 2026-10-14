import { STREAM_RETRY_BASE_MS, STREAM_RETRY_MAX_MS } from './config.js';

/**
 * Perfil Baseline: é o único com decodificação garantida em qualquer navegador/SO (ver
 * PLANO-COMPRESSAO-DE-VIDEO.md, seção 3.4). `avc1.42E01E` é Baseline, nível 3.0. Serve para
 * checar o suporte ao iniciar e como reserva quando o `avcC` do init segment não é legível.
 */
const CODEC_PADRAO = 'avc1.42E01E';
const tipoMp4 = (codec) => `video/mp4; codecs="${codec}"`;

/** Desiste (e cai para o MJPEG) depois de tantas quedas REAIS seguidas de `/stream.mp4`. */
const MAX_TENTATIVAS_DE_RECONEXAO = 5;

/** Atraso do ao vivo: entre o mínimo e o máximo, acelera suavemente; acima do máximo, pula. */
const ATRASO_MINIMO_S = 0.3;
const ATRASO_MAXIMO_S = 2;
/** Atraso abaixo do qual a velocidade volta a 1x (histerese, evita oscilar em 0,3 s). */
const ATRASO_ALCANCADO_S = 0.15;
const VELOCIDADE_ALCANCE = 1.1;
/** Folga mantida atrás da borda ao vivo ao pular. */
const FOLGA_AO_VIVO_S = 0.1;
const INTERVALO_VERIFICACAO_MS = 1000;
/** Mantém só tanto atrás do ponto de reprodução no SourceBuffer (memória). */
/** Quanto do fim do buffer sobra ao liberar a quota com tudo à frente do vídeo. */
const MARGEM_QUOTA_S = 0.5;
const MANTER_ATRAS_S = 10;
/** Sem `avcC` nem `moof` depois de tantos bytes, desiste de ler o codec e usa o padrão. */
const LIMITE_BYTES_PARA_CODEC = 64 * 1024;

/** Posição da primeira caixa MP4 com este tipo de 4 letras, ou -1. */
function acharCaixa(bytes, tipo) {
  const [a, b, c, d] = [...tipo].map((ch) => ch.charCodeAt(0));
  for (let i = 0; i + 3 < bytes.length; i += 1) {
    if (bytes[i] === a && bytes[i + 1] === b && bytes[i + 2] === c && bytes[i + 3] === d) return i;
  }
  return -1;
}

/**
 * Codec (`avc1.PPCCLL`) lido da caixa `avcC` do init segment: depois do tipo vêm
 * configurationVersion, profile, compatibilidade e level. `null` se não achar.
 */
export function codecDoInitSegment(bytes) {
  const i = acharCaixa(bytes, 'avcC');
  if (i < 0 || i + 7 >= bytes.length) return null;
  const hex = [bytes[i + 5], bytes[i + 6], bytes[i + 7]]
    .map((n) => n.toString(16).toUpperCase().padStart(2, '0'))
    .join('');
  return `avc1.${hex}`;
}

function juntar(a, b) {
  if (!a) return b;
  const todos = new Uint8Array(a.length + b.length);
  todos.set(a, 0);
  todos.set(b, a.length);
  return todos;
}

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
    return Impl.isTypeSupported(tipoMp4(CODEC_PADRAO));
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
   *           janela?: Window, fetchImpl?: Function, urlImpl?: typeof URL,
   *           agora?: () => number }} opcoes
   *   `janela`/`fetchImpl`/`urlImpl`/`agora` existem para os testes injetarem dublês.
   */
  constructor(videoElement, opcoes = {}) {
    this.video = videoElement;
    this.onFallback = opcoes.onFallback || (() => {});
    this.onEstado = opcoes.onEstado || (() => {});
    this.janela = opcoes.janela || (typeof window !== 'undefined' ? window : undefined);
    this.fetchImpl = opcoes.fetchImpl || (this.janela && this.janela.fetch ? this.janela.fetch.bind(this.janela) : undefined);
    this.urlImpl = opcoes.urlImpl || (this.janela ? this.janela.URL : undefined);
    this.agora = opcoes.agora || (() => Date.now());

    this.streamUrl = this.janela
      ? `${this.janela.location.protocol}//${this.janela.location.host}/stream.mp4`
      : '/stream.mp4';

    this.mediaSource = null;
    this.sourceBuffer = null;
    this.filaDePedacos = [];
    /** Bytes iniciais acumulados até dar para ler o codec (o SourceBuffer só nasce depois). */
    this.inicio = null;
    this.leitor = null;
    this.abortController = null;
    this.tentativas = 0;
    this.retryTimer = null;
    this.verificador = null;
    /** Pedido de transmitir está de pé — cai para `false` só em `stop()` ou desistência. */
    this.querTransmitir = false;
    /** O `<video>` está à mostra: só depois do evento `playing`, nunca no primeiro append. */
    this.mostrouVideo = false;
    /** Já avisou `onFallback`. */
    this.emFallback = false;
    /** Desistiu do H.264: nenhum `start()` seguinte tenta de novo nesta página (banda). */
    this.desistiu = false;
    /** O professor pausou: o servidor não manda nada, então parar de avançar é esperado. */
    this.pausado = false;
    /** Última posição vista do vídeo e quando: base da detecção de reprodução parada. */
    this.retentouQuota = false;

    // Muted + playsinline é o que permite o autoplay sem gesto (iOS inclusive).
    this.video.muted = true;
    this.video.playsInline = true;
    // Mesma classe do <img> do MJPEG (`.stream`, `display: none` por padrão); `.active` mostra.
    this.video.classList.remove('active');

    this.video.addEventListener('playing', () => this.aoReproduzir());
    for (const evento of ['waiting', 'stalled', 'timeupdate']) {
      this.video.addEventListener(evento, () => this.sincronizar());
    }
    this.video.addEventListener('error', () => {
      if (this.querTransmitir && !this.mostrouVideo) {
        this.aoFalhar('erro do elemento <video> antes do primeiro quadro');
      }
    });
    const doc = this.janela && this.janela.document;
    if (doc && doc.addEventListener) {
      doc.addEventListener('visibilitychange', () => this.aoMudarVisibilidade());
    }
  }

  /** Tenta iniciar a transmissão H.264. Sem suporte de MSE, cai para o MJPEG na hora. */
  start() {
    if (this.querTransmitir || this.desistiu) return;
    if (!mediaSourceSuportado(this.janela) || !this.fetchImpl) {
      this.cairParaFallback('sem suporte a MediaSource/fetch neste navegador');
      return;
    }
    this.querTransmitir = true;
    this.tentativas = 0;
    this.iniciarVerificador();
    this.conectar();
  }

  /** Encerra de propósito (aula parada/terminada) — não é uma queda para tentar de novo. */
  stop() {
    this.querTransmitir = false;
    this.pausado = false;
    this.limparTimer();
    this.pararVerificador();
    this.encerrarConexaoAtual();
    this.esconderVideo();
  }

  /**
   * O professor pausou/retomou. Tela parada NÃO é queda (o servidor não manda quadros), então
   * nada aqui reconecta; o estado só fica disponível para a interface.
   */
  definirPausado(pausado) {
    this.pausado = Boolean(pausado);
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
    // `ManagedMediaSource` (Safari em iOS/iPadOS 17.1+) exige este atributo antes de criar o objeto.
    if (usaManaged) {
      this.video.disableRemotePlayback = true;
    }
    const Impl = (janela && janela.MediaSource) || ManagedImpl;
    const ms = new Impl();
    this.mediaSource = ms;
    // Eventos de uma MediaSource que já não é a atual (encerrada por nós mesmos, via
    // `endOfStream()` ou ao tirar o `src`) chegam depois e não são queda de nada.
    ms.addEventListener('sourceopen', () => {
      if (ms === this.mediaSource) this.aoAbrirFonte();
    }, { once: true });
    for (const evento of ['sourceended', 'sourceclose']) {
      ms.addEventListener(evento, () => {
        if (ms === this.mediaSource) this.aoQuedaDeConexao(evento);
      });
    }

    const criarUrl = this.urlImpl && this.urlImpl.createObjectURL
      ? this.urlImpl.createObjectURL.bind(this.urlImpl)
      : null;
    if (!criarUrl) {
      this.aoFalhar('URL.createObjectURL indisponível');
      return;
    }
    this.objectUrlAtual = criarUrl(ms);
    this.video.src = this.objectUrlAtual;
  }

  /** Fonte aberta: o SourceBuffer só é criado quando o init segment revelar o codec. */
  aoAbrirFonte() {
    if (!this.querTransmitir) return;
    this.buscarStream();
  }

  criarSourceBuffer(codec) {
    const janela = this.janela;
    const Impl = (janela && janela.MediaSource) || (janela && janela.ManagedMediaSource);
    const tipo = tipoMp4(codec);
    if (Impl && typeof Impl.isTypeSupported === 'function' && !Impl.isTypeSupported(tipo)) {
      this.aoFalhar(`codec ${codec} não suportado neste navegador`);
      return false;
    }
    let sb;
    try {
      sb = this.mediaSource.addSourceBuffer(tipo);
    } catch (erro) {
      this.aoFalhar(`addSourceBuffer falhou: ${erro}`);
      return false;
    }
    this.sourceBuffer = sb;
    sb.addEventListener('updateend', () => {
      if (sb !== this.sourceBuffer) return;
      this.sincronizar();
      if (!this.aparar(MANTER_ATRAS_S)) this.escoarFila();
    });
    sb.addEventListener('error', () => {
      if (sb === this.sourceBuffer) this.aoQuedaDeConexao('erro do SourceBuffer');
    });
    return true;
  }

  async buscarStream() {
    const controle = typeof AbortController !== 'undefined' ? new AbortController() : null;
    this.abortController = controle;
    // Resposta de uma tentativa que já foi trocada por outra não é queda desta.
    const ehAtual = () => this.querTransmitir && this.abortController === controle;
    let resposta;
    try {
      resposta = await this.fetchImpl(this.streamUrl, {
        signal: controle ? controle.signal : undefined,
        cache: 'no-store'
      });
    } catch (erro) {
      if (!ehAtual()) return;
      this.aoQuedaDeConexao(`fetch falhou: ${erro}`);
      return;
    }
    if (!ehAtual()) return;
    if (!resposta || !resposta.ok || !resposta.body) {
      this.aoQuedaDeConexao(`resposta HTTP inválida (status ${resposta && resposta.status})`);
      return;
    }
    this.leitor = resposta.body.getReader();
    // Só `playing` zera as tentativas: HTTP 200 seguido de queda sem vídeo continua contando.
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
        if (value && value.byteLength) this.receberPedaco(value);
      }
    } catch (erro) {
      if (!this.querTransmitir || this.leitor !== leitor) return;
      this.aoQuedaDeConexao(`leitura falhou: ${erro}`);
    }
  }

  /** Os primeiros bytes são o init segment: acumula até ler o codec, e só então anexa. */
  receberPedaco(pedaco) {
    if (this.sourceBuffer) {
      this.filaDePedacos.push(pedaco);
      this.escoarFila();
      return;
    }
    this.inicio = juntar(this.inicio, pedaco);
    const codec = codecDoInitSegment(this.inicio);
    const semCodecParaLer = acharCaixa(this.inicio, 'moof') >= 0 || this.inicio.length >= LIMITE_BYTES_PARA_CODEC;
    if (!codec && !semCodecParaLer) return;
    const bytes = this.inicio;
    this.inicio = null;
    if (!this.criarSourceBuffer(codec || CODEC_PADRAO)) return;
    this.filaDePedacos.push(bytes);
    this.escoarFila();
  }

  /**
   * Manda o próximo pedaço da fila para o `SourceBuffer`, só se ele não estiver ocupado
   * (`updating`). `QuotaExceededError` não é queda de conexão: apara o que já passou e
   * tenta de novo uma vez.
   */
  escoarFila() {
    const sb = this.sourceBuffer;
    if (!sb || sb.updating || this.filaDePedacos.length === 0) return;
    const proximo = this.filaDePedacos.shift();
    try {
      sb.appendBuffer(proximo);
      this.retentouQuota = false;
    } catch (erro) {
      if (erro && erro.name === 'QuotaExceededError' && !this.retentouQuota && this.liberarQuota()) {
        this.retentouQuota = true;
        this.filaDePedacos.unshift(proximo);
        return;
      }
      this.aoQuedaDeConexao(`appendBuffer falhou: ${erro}`);
    }
  }

  /**
   * Quota cheia: apara o que já passou; se tudo está À FRENTE do ponto de reprodução (aba
   * oculta, o relógio não andou), descarta quase todo o buffer e salta para a borda ao vivo.
   */
  liberarQuota() {
    if (this.aparar(1)) return true;
    const sb = this.sourceBuffer;
    const faixas = sb && sb.buffered;
    if (!faixas || !faixas.length || sb.updating) return false;
    const inicio = faixas.start(0);
    const fim = faixas.end(faixas.length - 1);
    const corte = fim - MARGEM_QUOTA_S;
    if (!(corte > inicio)) return false;
    try {
      sb.remove(inicio, corte);
      this.video.currentTime = fim - FOLGA_AO_VIVO_S;
      return true;
    } catch (_) {
      return false;
    }
  }

  /** Remove do buffer o que ficou mais de `margem` segundos atrás do ponto de reprodução. */
  aparar(margem) {
    const sb = this.sourceBuffer;
    const faixas = sb && sb.buffered;
    if (!faixas || !faixas.length || sb.updating) return false;
    const limite = this.video.currentTime - margem;
    if (!(faixas.start(0) < limite)) return false;
    try {
      sb.remove(0, limite);
      return true;
    } catch (_) {
      return false;
    }
  }

  /**
   * Mantém a reprodução na borda ao vivo: leva o `currentTime` para dentro do que está
   * bufferizado (late joiner: o servidor não zera o `tfdt`, o vídeo começa em ~1800 s),
   * pula buracos (o servidor descarta fila de cliente lento) e corta o atraso acumulado.
   */
  sincronizar() {
    const sb = this.sourceBuffer;
    const faixas = sb && sb.buffered;
    if (!faixas || !faixas.length) return;
    const t = this.video.currentTime;
    const fim = faixas.end(faixas.length - 1);
    let alvo = null;
    if (this.faixaQueContem(faixas, t) >= 0) {
      const atraso = fim - t;
      if (atraso > ATRASO_MAXIMO_S) alvo = fim - FOLGA_AO_VIVO_S;
      else this.ajustarVelocidade(atraso);
    } else if (t < faixas.start(0)) {
      alvo = Math.max(faixas.start(0), fim - FOLGA_AO_VIVO_S);
    } else {
      for (let i = 0; i < faixas.length; i += 1) {
        if (faixas.start(i) > t) { alvo = faixas.start(i); break; }
      }
    }
    if (alvo !== null) {
      this.video.currentTime = alvo;
      this.ajustarVelocidade(0);
    }
    if (this.video.paused) this.tocar();
  }

  /** Recupera atraso moderado acelerando um pouco (sem o tranco de um seek); 1x ao alcançar. */
  ajustarVelocidade(atraso) {
    const v = this.video;
    if (atraso > ATRASO_MINIMO_S) {
      if (v.playbackRate !== VELOCIDADE_ALCANCE) v.playbackRate = VELOCIDADE_ALCANCE;
    } else if (atraso <= ATRASO_ALCANCADO_S && v.playbackRate !== 1) {
      v.playbackRate = 1;
    }
  }

  /** Índice da faixa bufferizada que contém `t`, ou -1 (buraco, antes ou depois de tudo). */
  faixaQueContem(faixas, t) {
    for (let i = 0; i < faixas.length; i += 1) {
      if (t >= faixas.start(i) && t <= faixas.end(i)) return i;
    }
    return -1;
  }

  tocar() {
    if (typeof this.video.play !== 'function') return;
    try {
      const promessa = this.video.play();
      if (promessa && typeof promessa.catch === 'function') promessa.catch(() => {});
    } catch (_) { /* autoplay bloqueado: a detecção de parada cuida */ }
  }

  /** `playing`: só agora há imagem de verdade, então só agora o <video> cobre o palco. */
  aoReproduzir() {
    if (!this.querTransmitir || !this.sourceBuffer) return;
    this.tentativas = 0;
    if (this.mostrouVideo) return;
    this.mostrouVideo = true;
    this.video.classList.add('active');
    this.onEstado('ao-vivo');
  }

  aoMudarVisibilidade() {
    const doc = this.janela && this.janela.document;
    if (!doc || doc.visibilityState === 'hidden') return;
    this.sincronizar();
  }

  iniciarVerificador() {
    if (this.verificador) return;
    this.verificador = setInterval(() => this.verificar(), INTERVALO_VERIFICACAO_MS);
    if (this.verificador && typeof this.verificador.unref === 'function') this.verificador.unref();
  }

  pararVerificador() {
    if (this.verificador) clearInterval(this.verificador);
    this.verificador = null;
  }

  /** Tique de ~1 s: persegue a borda ao vivo. Tela parada (sem quadros novos) é normal, não queda. */
  verificar() {
    if (!this.querTransmitir || !this.sourceBuffer) return;
    this.sincronizar();
  }

  /**
   * A conexão HTTP caiu de verdade: tenta de novo com espera crescente antes de desistir.
   * Eventos de conexões antigas são filtrados antes de chegar aqui.
   */
  aoQuedaDeConexao(motivo) {
    if (!this.querTransmitir) return;
    this.encerrarConexaoAtual();
    this.esconderVideo();
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
    const primeiraVez = !this.emFallback;
    this.emFallback = true;
    this.desistiu = true;
    this.querTransmitir = false;
    this.limparTimer();
    this.pararVerificador();
    this.encerrarConexaoAtual();
    this.esconderVideo();
    if (primeiraVez) this.onFallback(motivo);
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
    // Zera o estado ANTES de mexer na fonte: os eventos que isso dispara (síncronos ou não)
    // já a encontram como "não atual".
    const ms = this.mediaSource;
    const sb = this.sourceBuffer;
    this.mediaSource = null;
    this.sourceBuffer = null;
    this.leitor = null;
    this.filaDePedacos = [];
    this.inicio = null;
    this.retentouQuota = false;
    if (sb && ms) {
      try { ms.removeSourceBuffer(sb); } catch (_) { /* já não pertence à fonte */ }
    }
    if (ms && ms.readyState === 'open') {
      try { ms.endOfStream(); } catch (_) { /* nada a encerrar */ }
    }
    if (this.objectUrlAtual && this.urlImpl && this.urlImpl.revokeObjectURL) {
      this.urlImpl.revokeObjectURL(this.objectUrlAtual);
    }
    this.objectUrlAtual = null;
    if (this.video.getAttribute('src')) {
      this.video.removeAttribute('src');
    }
  }
}
