/**
 * Painel de depuração do aluno (inspeção de rede). Só existe quando o servidor diz
 * `metricas: "true"` no CONNECTED (build de depuração): sem isso este módulo nunca é
 * instanciado — nenhum nó no DOM, relógio, ouvinte nem `window.AulaCastDebug`.
 *
 * Os outros módulos só chamam `globalThis.AulaCastDebug?.log(...)`, que é inofensivo sem o painel.
 * Nada do texto do chat passa por aqui.
 */
export const MAX_LINHAS_LOG = 500;
export const INTERVALO_VIDEO_MS = 2000;
export const INTERVALO_RTT_MS = 10000;
/** A cada tantos fragmentos recebidos, uma linha de resumo. */
export const FRAGMENTOS_POR_LINHA = 30;

/** O que o painel explica ao aluno: curto, técnico e fiel ao código (docs/04, seções 1-3). */
export const TEXTO_EXPLICATIVO = [
  'Captura: o ScreenCaptureKit entrega os quadros da tela do professor a dois codificadores: H.264 (VideoToolbox, perfil Baseline, taxa-alvo de 1,2 a 4 Mbps) e JPEG.',
  'Servidor: HTTP/WebSocket embutido (Network.framework) na porta fixa 8080. Nome aulacast.local por mDNS e serviço Bonjour. É unicast TCP, um fluxo por aluno, sem multicast.',
  'Cada aluno abre um WebSocket /ws (JSON de controle: IDENTIFY, chat, presença, PING a cada 10 s; o servidor derruba a conexão muda após 30 s) e uma conexão HTTP persistente de vídeo.',
  'Rota H.264: /stream.mp4 é MP4 fragmentado (fMP4) sobre HTTP, injetado num SourceBuffer do MediaSource. O init segment vem primeiro e quem entra recebe um quadro-chave (IDR) em seguida.',
  'Rota de reserva: /stream, MJPEG multipart (um JPEG por parte). O navegador cai nela sem MediaSource/codec ou se o /stream.mp4 falhar repetidas vezes.',
  'Limites do servidor: 4 conexões /stream.mp4 por IP e 120 no total; fila por cliente de 1 MB ou 1 s (acima disso descarta e pede quadro-chave); pedidos de quadro-chave agrupados em 1 por segundo; quadro-chave pelo menos a cada 2 s.',
  'Borda ao vivo: o fim do buffer; o atraso é (fim do buffer - currentTime). Acima de 0,3 s o player usa playbackRate 1,1x para alcançar (volta a 1x com 0,15 s); acima de 2 s salta para a borda.',
  'O buffer é aparado: só os últimos 10 s atrás do ponto de reprodução ficam no SourceBuffer; em QuotaExceededError ele libera espaço e salta para a borda ao vivo.'
];

const pad = (n, w = 2) => String(n).padStart(w, '0');
export function carimbo(d) {
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

function resumoDados(dados) {
  if (dados === undefined || dados === null) return '';
  if (typeof dados === 'string') return dados;
  try { return JSON.stringify(dados); } catch (_) { return String(dados); }
}

/**
 * Conta caixas `moof` (fragmentos) e quadros-chave num pedaço do fMP4. O empacotador escreve
 * 1 amostra por `trun`; os flags dela ficam 24 bytes depois do tipo e `depends_on = 2` (bits
 * 25-24) marca quadro-chave. Um `trun` partido entre dois pedaços não entra na conta. O(bytes).
 */
export function contarFragmentos(bytes) {
  let fragmentos = 0;
  let chave = 0;
  for (let i = 0; i + 3 < bytes.length; i += 1) {
    if (bytes[i] === 0x6d && bytes[i + 1] === 0x6f && bytes[i + 2] === 0x6f && bytes[i + 3] === 0x66) {
      fragmentos += 1; // moof
    } else if (bytes[i] === 0x74 && bytes[i + 1] === 0x72 && bytes[i + 2] === 0x75 && bytes[i + 3] === 0x6e && i + 24 < bytes.length) {
      if ((bytes[i + 24] & 0x03) === 0x02) chave += 1; // trun
    }
  }
  return { fragmentos, chave };
}

export class DebugPanel {
  /**
   * @param {{ doc?: Document, win?: object, video?: HTMLVideoElement, agora?: Function,
   *   console?: object, setIntervalImpl?: Function, clearIntervalImpl?: Function }} o
   */
  constructor({
    doc = document, win = globalThis, video = null, agora = () => new Date(), console: cons = console,
    setIntervalImpl = (f, ms) => { const t = setInterval(f, ms); t?.unref?.(); return t; },
    clearIntervalImpl = (t) => clearInterval(t)
  } = {}) {
    Object.assign(this, { doc, win, video, agora, cons, setIntervalImpl, clearIntervalImpl });
    this.linhas = [];
    this.timers = [];
    this.rtts = [];
    this.frag = { n: 0, bytes: 0, chave: 0, ultimoLog: 0, bytesDesdeLog: 0, chaveDesdeLog: 0 };
    this.jaExplicou = false;
    this.ativo = false;
  }

  /**
   * Liga os relógios e o global `AulaCastDebug`. Idempotente. NÃO cria nenhum elemento na página:
   * tudo aparece no console do navegador (Inspecionar > Console).
   */
  ativar() {
    if (this.ativo) return;
    this.ativo = true;
    this.win.AulaCastDebug = {
      log: (cat, msg, dados) => this.log(cat, msg, dados),
      rtt: (ms) => this.registrarRtt(ms),
      fragmentos: (bytes) => this.registrarFragmentos(bytes),
      // Comandos para digitar no console.
      texto: () => this.textoDoLog(),
      copiar: () => this.copiar(),
      baixar: () => this.baixar(),
      ajuda: () => this.ajuda()
    };
    this.timers.push(this.setIntervalImpl(() => this.amostrarVideo(), INTERVALO_VIDEO_MS));
    this.timers.push(this.setIntervalImpl(() => this.resumirRtt(), INTERVALO_RTT_MS));
    this.doc.addEventListener('visibilitychange', () => this.log('pagina', `visibilidade: ${this.doc.visibilityState}`));
    this.log('debug', 'depuração ativada pelo servidor (CONNECTED.metricas); só no console');
  }

  desativar() {
    if (!this.ativo) return;
    this.timers.forEach((t) => this.clearIntervalImpl(t));
    this.timers = [];
    delete this.win.AulaCastDebug;
    this.ativo = false;
  }

  el(tag, classe, texto) {
    const e = this.doc.createElement(tag);
    if (classe) e.className = classe;
    if (texto !== undefined) e.textContent = texto;
    return e;
  }

  /** Uma vez, quando o aluno entra: explica o sistema no console e diz como copiar o log. */
  aoIdentificar() {
    if (!this.ativo || this.jaExplicou) return;
    this.jaExplicou = true;
    this.cons.info(`[AulaCast debug] Como o sistema funciona:\n${TEXTO_EXPLICATIVO.map((t) => `• ${t}`).join('\n')}`);
    this.ajuda();
  }

  ajuda() {
    this.cons.info('[AulaCast debug] Comandos: AulaCastDebug.texto() mostra o log, .copiar() copia, .baixar() salva um .txt, .ajuda() repete esta mensagem.');
  }

  log(categoria, msg, dados) {
    if (!this.ativo) return;
    const extra = resumoDados(dados);
    const linha = `${carimbo(this.agora())} [${categoria}] ${msg}${extra ? ` ${extra}` : ''}`;
    this.cons.log(`[AulaCast debug] ${linha}`);
    this.linhas.push(linha);
    if (this.linhas.length > MAX_LINHAS_LOG) this.linhas.shift();
  }

  registrarRtt(ms) {
    this.log('ws', `PONG rtt ${ms} ms`);
    this.rtts.push(ms);
  }

  resumirRtt() {
    if (!this.rtts.length) return;
    const min = Math.min(...this.rtts);
    const max = Math.max(...this.rtts);
    const media = this.rtts.reduce((a, b) => a + b, 0) / this.rtts.length;
    this.log('ws', `RTT em ${this.rtts.length} amostra(s): min ${min} / média ${media.toFixed(1)} / máx ${max} ms`);
    this.rtts = [];
  }

  /** Um pedaço de `/stream.mp4`: acumula e escreve uma linha a cada `FRAGMENTOS_POR_LINHA`. */
  registrarFragmentos(bytes) {
    const f = this.frag;
    const { fragmentos, chave } = contarFragmentos(bytes);
    f.n += fragmentos;
    f.bytes += bytes.length;
    f.chave += chave;
    f.bytesDesdeLog += bytes.length;
    f.chaveDesdeLog += chave;
    if (f.n - f.ultimoLog >= FRAGMENTOS_POR_LINHA) {
      this.log('fmp4', `+${f.n - f.ultimoLog} fragmentos, ${f.bytesDesdeLog} bytes, ${f.chaveDesdeLog} quadro(s)-chave `
        + `(total ${f.n} fragmentos, ${f.bytes} bytes, ${f.chave} chaves)`);
      f.ultimoLog = f.n;
      f.bytesDesdeLog = 0;
      f.chaveDesdeLog = 0;
    }
  }

  /** A cada 2 s: faixas bufferizadas, atraso até a borda ao vivo, velocidade e quadros. */
  amostrarVideo() {
    const v = this.video;
    if (!v) return;
    const faixas = [];
    const b = v.buffered;
    for (let i = 0; b && i < b.length; i += 1) faixas.push(`${b.start(i).toFixed(2)}-${b.end(i).toFixed(2)}`);
    const lag = b && b.length ? ((b.end(b.length - 1) - v.currentTime) * 1000).toFixed(0) : 'n/d';
    const q = typeof v.getVideoPlaybackQuality === 'function' ? v.getVideoPlaybackQuality() : null;
    this.log('video', `buffered [${faixas.join(' ')}] t=${(v.currentTime ?? 0).toFixed(2)} atraso ${lag} ms rate ${v.playbackRate}`
      + (q ? ` quadros ${q.totalVideoFrames} perdidos ${q.droppedVideoFrames}` : ''));
  }

  textoDoLog() {
    return this.linhas.join('\n');
  }

  /** Clipboard API só existe em contexto seguro; em http usa textarea oculta + execCommand. */
  async copiar() {
    const texto = this.textoDoLog();
    const clip = this.win.navigator?.clipboard;
    if (clip?.writeText && this.win.isSecureContext) {
      try {
        await clip.writeText(texto);
        this.cons.info('[AulaCast debug] log copiado');
        return true;
      } catch (_) { /* cai no plano B */ }
    }
    const ta = this.el('textarea');
    ta.value = texto;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    this.doc.body.appendChild(ta);
    ta.select?.();
    let ok = false;
    try { ok = Boolean(this.doc.execCommand('copy')); } catch (_) { ok = false; }
    this.doc.body.removeChild(ta);
    this.cons.info(ok ? '[AulaCast debug] log copiado (modo http)' : '[AulaCast debug] não foi possível copiar; use AulaCastDebug.baixar()');
    return ok;
  }

  baixar() {
    const { URL: url, Blob: Bolha } = this.win;
    const a = this.el('a');
    a.href = url.createObjectURL(new Bolha([this.textoDoLog()], { type: 'text/plain;charset=utf-8' }));
    a.download = `aulacast-debug-${this.agora().toISOString().replace(/[:.]/g, '-')}.txt`;
    this.doc.body.appendChild(a);
    a.click();
    this.doc.body.removeChild(a);
    url.revokeObjectURL(a.href);
  }
}
