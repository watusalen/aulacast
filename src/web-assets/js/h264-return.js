/**
 * Volta ao H.264 depois de um fallback para MJPEG.
 *
 * O MJPEG gasta bem mais banda, então ficar nele para sempre não serve: depois de cair, a
 * página tenta o H.264 de novo sozinha, com espera crescente (a rede pode ter se recuperado).
 * Cada tentativa é uma prova curta feita pelo `VideoStreamPlayer.tentarDeNovo()`; este objeto
 * só decide QUANDO tentar. Dois pedidos de agendamento seguidos não geram dois relógios.
 */
export const ESPERAS_DE_RETORNO_MS = [30_000, 60_000, 120_000, 300_000];

/**
 * Teto de provas que de fato rodaram sem o H.264 voltar (~1 hora): falha permanente (codec,
 * autoplay bloqueado) não pode abrir uma segunda conexão e pedir quadro-chave para sempre.
 * Zera quando o H.264 volta (`recuperou()`).
 */
export const MAXIMO_DE_PROVAS = 10;

/** `setTimeout` que, no Node (testes), não segura o processo aberto; no navegador não há `unref`. */
function relogioPadrao(...args) {
  const id = setTimeout(...args);
  if (id && typeof id.unref === 'function') id.unref();
  return id;
}

export class RetornoAoH264 {
  /**
   * @param {{ tentar: () => void, podeTentar?: () => boolean,
   *           esperas?: number[], setTimer?: Function, clearTimer?: Function }} opcoes
   */
  constructor({ tentar, podeTentar = () => true, esperas = ESPERAS_DE_RETORNO_MS,
    setTimer = relogioPadrao, clearTimer = (t) => clearTimeout(t), sorteio = Math.random,
    maximo = MAXIMO_DE_PROVAS }) {
    this.sorteio = sorteio;
    this.maximo = maximo;
    this.tentar = tentar;
    this.podeTentar = podeTentar;
    this.esperas = esperas;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.tentativas = 0;
    this.timer = null;
  }

  /** Marca a próxima prova. Sem efeito se já houver uma marcada. */
  agendar() {
    if (this.timer || this.tentativas >= this.maximo) return;
    // Sorteada entre 1x e 2x a base: se vários participantes caírem juntos (queda do Wi-Fi),
    // eles não voltam todos no mesmo segundo e derrubam a rede de novo; a volta é gradual.
    const base = this.esperas[Math.min(this.tentativas, this.esperas.length - 1)];
    const espera = Math.round(base * (1 + this.sorteio()));
    this.timer = this.setTimer(() => {
      this.timer = null;
      // Pausada, encerrada ou aba oculta: não é hora, e isso NÃO gasta uma das provas.
      if (!this.podeTentar()) {
        this.agendar();
        return;
      }
      this.tentativas += 1;
      // Já havia uma prova em andamento (ou nada a tentar): garante que não fica sem marcação.
      if (this.tentar() === false) this.agendar();
    }, espera);
  }

  /** O H.264 voltou de verdade: zera a espera e cancela o que estava marcado. */
  recuperou() {
    this.tentativas = 0;
    this.cancelar();
  }

  cancelar() {
    if (this.timer) this.clearTimer(this.timer);
    this.timer = null;
  }
}
