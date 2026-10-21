/**
 * Métricas do vídeo no console do navegador (DevTools) e no servidor.
 *
 * A cada 2 s calcula o que ESTE aluno recebe (fps decodificado, Mbps, quadros perdidos e
 * atraso até o ao vivo), escreve no console e manda `METRICS`. O servidor devolve
 * `METRICS_TABLE` com a turma toda, e isso também vai só para o console: nenhum nome é
 * inserido na página.
 *
 * Só de depuração: fica totalmente ocioso (sem relógio, sem envio, sem console) até o servidor
 * dizer `metricas: "true"` no CONNECTED, o que só acontece em build de depuração.
 *
 * Na rota MJPEG o navegador não tem evento por quadro: informa só a rota, e o resto fica
 * `null` (nada é inventado).
 */
const PREFIXO = '[AulaCast métricas]';
export const INTERVALO_METRICAS_MS = 2000;

const arredondar = (n, casas) => Math.round(n * 10 ** casas) / 10 ** casas;
const ehNumero = (n) => typeof n === 'number' && Number.isFinite(n);
const numeroOuNull = (n) => (ehNumero(n) ? n : null);
const texto = (v, max) => (typeof v === 'string' && v ? v.slice(0, max) : null);

export const TIPOS_DE_EVENTO = ['rota', 'video_reconexao', 'quota', 'seek', 'ws_reconexao'];
export const EVENTOS_POR_SEGUNDO = 5;
const MAX_CHAVES_DE_EVENTO = 6;

/** `navigator.connection` só existe no Chrome/Android: nos outros, `null` (nada inventado). */
export function lerConexao(nav = globalThis.navigator) {
  const c = nav && nav.connection;
  if (!c) return null;
  return { tipo: texto(c.effectiveType, 16), downlinkMbps: numeroOuNull(c.downlink), rttMs: numeroOuNull(c.rtt) };
}

/** Dados do aparelho, mandados uma vez (`ENV`). */
export function lerAmbiente(nav = globalThis.navigator, tela = globalThis.screen, dpr = globalThis.devicePixelRatio) {
  nav = nav || {};
  tela = tela || {};
  return {
    userAgent: texto(nav.userAgent, 200),
    plataforma: texto((nav.userAgentData && nav.userAgentData.platform) || nav.platform, 40),
    telaLarg: numeroOuNull(tela.width),
    telaAlt: numeroOuNull(tela.height),
    dpr: numeroOuNull(dpr),
    idioma: texto(nav.language, 16),
    conexao: lerConexao(nav)
  };
}

/** Objeto plano, no máximo 6 chaves, textos até 80 caracteres e números finitos; o resto cai. */
export function limparDados(dados) {
  const saida = {};
  if (!dados || typeof dados !== 'object') return saida;
  for (const [k, v] of Object.entries(dados)) {
    if (Object.keys(saida).length >= MAX_CHAVES_DE_EVENTO) break;
    if (ehNumero(v)) saida[k] = v;
    else if (typeof v === 'string') saida[k] = v.slice(0, 80);
  }
  return saida;
}

const visivelAgora = () => typeof document !== 'undefined'
  && document.visibilityState === 'visible'
  && (typeof document.hasFocus !== 'function' || document.hasFocus());

export class MetricsReporter {
  /**
   * @param {{ enviar: Function, lerEstatisticas: Function, ativo?: Function, log?: object,
   *   agora?: Function, lerRtt?: Function, lerVisivel?: Function, lerAmbienteImpl?: Function, lerConexaoImpl?: Function, intervaloMs?: number, setIntervalImpl?: Function, clearIntervalImpl?: Function }} o
   */
  constructor({
    enviar, lerEstatisticas, ativo = () => true, log = console,
    agora = () => Date.now(), lerRtt = () => null, lerVisivel = visivelAgora,
    lerAmbienteImpl = lerAmbiente, lerConexaoImpl = lerConexao, intervaloMs = INTERVALO_METRICAS_MS,
    // unref: num processo Node (testes) o relógio não pode impedir o encerramento.
    setIntervalImpl = (f, ms) => { const t = setInterval(f, ms); t?.unref?.(); return t; },
    clearIntervalImpl = (t) => clearInterval(t)
  }) {
    Object.assign(this, { enviar, lerEstatisticas, ativo, log, agora, lerRtt, lerVisivel, lerAmbienteImpl, lerConexaoImpl, intervaloMs, setIntervalImpl, clearIntervalImpl });
    this.timer = null;
    this.habilitado = false;
    /** Leitura anterior, base das diferenças; `null` até a primeira leitura com a aula ao vivo. */
    this.anterior = null;
    this.envEnviado = false;
    /** Instantes (ms) dos últimos eventos enviados, para o limite por segundo. */
    this.recentes = [];
  }

  /** O servidor avisou (ou deixou de avisar) que as métricas estão ligadas. */
  definirHabilitado(habilitado) {
    this.habilitado = Boolean(habilitado);
    // Cada conexão nova do WebSocket recebe um CONNECTED: o servidor não conhece o navegador dela
    // até receber o ENV de novo, então a reconexão rearma o envio.
    if (this.habilitado) this.envEnviado = false;
    if (!this.habilitado) this.parar();
    // Gancho global para quem não importa este módulo (socket, player); só existe com a flag.
    if (this.habilitado) globalThis.AulaCastMetricas = { evento: (tipo, dados) => this.evento(tipo, dados) };
    else delete globalThis.AulaCastMetricas;
  }

  /** `EVENT`: tipo na lista fixa, dados planos, no máximo 5 por segundo; nunca texto de chat. */
  evento(tipo, dados) {
    if (!this.habilitado || !TIPOS_DE_EVENTO.includes(tipo)) return false;
    const t = this.agora();
    this.recentes = this.recentes.filter((x) => t - x < 1000);
    if (this.recentes.length >= EVENTOS_POR_SEGUNDO) return false;
    this.recentes.push(t);
    this.enviar({ type: 'EVENT', payload: { tipo, dados: limparDados(dados) } });
    return true;
  }

  iniciar() {
    if (!this.habilitado || this.timer) return;
    this.timer = this.setIntervalImpl(() => this.amostrar(), this.intervaloMs);
  }

  parar() {
    if (this.timer) this.clearIntervalImpl(this.timer);
    this.timer = null;
    this.anterior = null;
  }

  /** Uma leitura. Silenciosa com a aula pausada/encerrada ou o aluno sem identificação. */
  amostrar() {
    if (!this.habilitado) return;
    if (!this.ativo()) {
      this.anterior = null;
      return;
    }
    if (!this.envEnviado) {
      this.envEnviado = true;
      this.enviar({ type: 'ENV', payload: this.lerAmbienteImpl() });
    }
    const leitura = this.lerEstatisticas();
    if (!leitura) return;
    const t = this.agora();
    const comum = () => ({
      rttMs: numeroOuNull(this.lerRtt()),
      visivel: Boolean(this.lerVisivel()),
      conexao: this.lerConexaoImpl()
    });

    if (leitura.rota !== 'H.264') {
      this.anterior = null;
      this.publicar({
        rota: leitura.rota, fps: null, mbps: null, dropped: null, droppedTotal: null, lagMs: null,
        bufferS: null, playbackRate: null, ...comum()
      });
      return;
    }

    const base = this.anterior;
    this.anterior = { t, bytes: leitura.bytes, quadros: leitura.quadros, perdidos: leitura.perdidos };
    const segundos = base ? (t - base.t) / 1000 : 0;
    if (segundos <= 0) return; // primeira leitura: só fixa a base
    this.publicar({
      rota: 'H.264',
      fps: this.taxa(leitura.quadros, base.quadros, segundos, 1),
      mbps: this.taxa(leitura.bytes, base.bytes, segundos, 2, 8 / 1e6),
      dropped: this.delta(leitura.perdidos, base.perdidos),
      droppedTotal: numeroOuNull(leitura.perdidos),
      lagMs: ehNumero(leitura.lagMs) ? Math.round(leitura.lagMs) : null,
      bufferS: ehNumero(leitura.bufferS) ? arredondar(leitura.bufferS, 2) : null,
      playbackRate: numeroOuNull(leitura.playbackRate),
      ...comum()
    });
  }

  /** Quantos quadros perdidos neste intervalo; `null` se faltar um dos contadores. */
  delta(agora, antes) {
    return ehNumero(agora) && ehNumero(antes) && agora >= antes ? agora - antes : null;
  }

  /** Diferença por segundo entre dois contadores; `null` se faltar um ou ele tiver recuado. */
  taxa(agora, antes, segundos, casas, fator = 1) {
    if (!ehNumero(agora) || !ehNumero(antes) || agora < antes) return null;
    return arredondar(((agora - antes) * fator) / segundos, casas);
  }

  publicar(m) {
    const fmt = (v, un) => (v === null ? 'n/d' : `${v} ${un}`);
    const linha = `você: rota ${m.rota} | ${fmt(m.fps, 'fps')} | ${fmt(m.mbps, 'Mbps')} | `
      + `perdidos ${fmt(m.dropped, 'quadros')} | atraso ${fmt(m.lagMs, 'ms')}`;
    this.log.log(`${PREFIXO} ${linha}`);
    globalThis.AulaCastDebug?.log('metricas', linha);
    this.enviar({ type: 'METRICS', payload: m });
  }

  /** `METRICS_TABLE` do servidor: uma linha de resumo e a tabela por aluno, só no console. */
  aoReceberTabela(payload) {
    if (!this.habilitado || !payload || typeof payload !== 'object') return;
    const n = (v) => (ehNumero(v) ? arredondar(v, 1) : 'n/d');
    const resumo = `turma: ${n(payload.alunos)} alunos (H.264 ${n(payload.alunosH264)} / MJPEG `
      + `${n(payload.alunosMJPEG)}) | tela ${n(payload.telaFps)} fps | por aluno: média ${n(payload.mediaFps)}, `
      + `mínimo ${n(payload.minimoFps)} fps | ${n(payload.mbps)} Mbps (servidor)`;
    this.log.log(`${PREFIXO} ${resumo}`);
    globalThis.AulaCastDebug?.log('metricas', `${resumo} | filas estouradas ${n(payload.estourosDeFila)}, `
      + `pedidos de quadro-chave ${n(payload.pedidosDeQuadroChave)}, bytes totais ${n(payload.bytesTotais)}`);
    const linhas = Array.isArray(payload.rows) ? payload.rows : [];
    this.log.table(linhas.map((l) => ({
      nome: l.nome, rota: l.rota, fps: l.fps, mbps: l.mbps, dropped: l.dropped, lagMs: l.lagMs
    })));
  }
}
