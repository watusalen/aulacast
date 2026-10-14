/**
 * Métricas do vídeo no console do navegador (DevTools) e no servidor.
 *
 * A cada 5 s calcula o que ESTE aluno recebe (fps decodificado, Mbps, quadros perdidos e
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
export const INTERVALO_METRICAS_MS = 5000;

const arredondar = (n, casas) => Math.round(n * 10 ** casas) / 10 ** casas;
const ehNumero = (n) => typeof n === 'number' && Number.isFinite(n);

export class MetricsReporter {
  /**
   * @param {{ enviar: Function, lerEstatisticas: Function, ativo?: Function, log?: object,
   *   agora?: Function, intervaloMs?: number, setIntervalImpl?: Function, clearIntervalImpl?: Function }} o
   */
  constructor({
    enviar, lerEstatisticas, ativo = () => true, log = console,
    agora = () => Date.now(), intervaloMs = INTERVALO_METRICAS_MS,
    // unref: num processo Node (testes) o relógio não pode impedir o encerramento.
    setIntervalImpl = (f, ms) => { const t = setInterval(f, ms); t?.unref?.(); return t; },
    clearIntervalImpl = (t) => clearInterval(t)
  }) {
    Object.assign(this, { enviar, lerEstatisticas, ativo, log, agora, intervaloMs, setIntervalImpl, clearIntervalImpl });
    this.timer = null;
    this.habilitado = false;
    /** Leitura anterior, base das diferenças; `null` até a primeira leitura com a aula ao vivo. */
    this.anterior = null;
  }

  /** O servidor avisou (ou deixou de avisar) que as métricas estão ligadas. */
  definirHabilitado(habilitado) {
    this.habilitado = Boolean(habilitado);
    if (!this.habilitado) this.parar();
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
    const leitura = this.lerEstatisticas();
    if (!leitura) return;
    const t = this.agora();

    if (leitura.rota !== 'H.264') {
      this.anterior = null;
      this.publicar({ rota: leitura.rota, fps: null, mbps: null, dropped: null, lagMs: null });
      return;
    }

    const base = this.anterior;
    this.anterior = { t, bytes: leitura.bytes, quadros: leitura.quadros };
    const segundos = base ? (t - base.t) / 1000 : 0;
    if (segundos <= 0) return; // primeira leitura: só fixa a base
    this.publicar({
      rota: 'H.264',
      fps: this.taxa(leitura.quadros, base.quadros, segundos, 1),
      mbps: this.taxa(leitura.bytes, base.bytes, segundos, 2, 8 / 1e6),
      dropped: ehNumero(leitura.perdidos) ? leitura.perdidos : null,
      lagMs: ehNumero(leitura.lagMs) ? Math.round(leitura.lagMs) : null
    });
  }

  /** Diferença por segundo entre dois contadores; `null` se faltar um ou ele tiver recuado. */
  taxa(agora, antes, segundos, casas, fator = 1) {
    if (!ehNumero(agora) || !ehNumero(antes) || agora < antes) return null;
    return arredondar(((agora - antes) * fator) / segundos, casas);
  }

  publicar(m) {
    const fmt = (v, un) => (v === null ? 'n/d' : `${v} ${un}`);
    this.log.log(`${PREFIXO} você: rota ${m.rota} | ${fmt(m.fps, 'fps')} | ${fmt(m.mbps, 'Mbps')} | `
      + `perdidos ${fmt(m.dropped, 'quadros')} | atraso ${fmt(m.lagMs, 'ms')}`);
    this.enviar({ type: 'METRICS', payload: m });
  }

  /** `METRICS_TABLE` do servidor: uma linha de resumo e a tabela por aluno, só no console. */
  aoReceberTabela(payload) {
    if (!this.habilitado || !payload || typeof payload !== 'object') return;
    const n = (v) => (ehNumero(v) ? arredondar(v, 1) : 'n/d');
    this.log.log(`${PREFIXO} turma: ${n(payload.alunos)} alunos (H.264 ${n(payload.alunosH264)} / MJPEG `
      + `${n(payload.alunosMJPEG)}) | tela ${n(payload.telaFps)} fps | por aluno: média ${n(payload.mediaFps)}, `
      + `mínimo ${n(payload.minimoFps)} fps | ${n(payload.mbps)} Mbps (servidor)`);
    const linhas = Array.isArray(payload.rows) ? payload.rows : [];
    this.log.table(linhas.map((l) => ({
      nome: l.nome, rota: l.rota, fps: l.fps, mbps: l.mbps, dropped: l.dropped, lagMs: l.lagMs
    })));
  }
}
