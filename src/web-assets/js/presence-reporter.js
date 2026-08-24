/**
 * Informa ao professor se o aluno está de fato com a aula à vista.
 *
 * Cada evento declara a intenção em vez de consultar `document.hasFocus()` na hora:
 * durante o próprio `blur` o navegador ainda pode responder que a janela tem foco,
 * e aí sair da página clicando em outro app não era detectado.
 */
export class PresenceReporter {
  constructor(enviar, doc = document) {
    this.enviar = enviar;
    this.doc = doc;
    this.ultimoEnviado = null;
  }

  /** Estado consultado (confiável fora dos handlers de foco). */
  estadoAtual() {
    const visivel = this.doc.visibilityState === 'visible';
    const comFoco = typeof this.doc.hasFocus === 'function' ? this.doc.hasFocus() : true;
    return visivel && comFoco;
  }

  /** A janela perdeu o foco: o aluno clicou em outro app ou outra janela. */
  aoPerderFoco() {
    this.reportar(false);
  }

  /** A janela voltou ao foco. */
  aoGanharFoco() {
    this.reportar(true);
  }

  /** Trocou de aba, minimizou ou voltou. */
  aoMudarVisibilidade() {
    this.reportar(this.doc.visibilityState === 'visible' ? this.estadoAtual() : false);
  }

  /** Envio inicial e após reconectar, quando o servidor não sabe mais nada sobre nós. */
  sincronizar() {
    this.ultimoEnviado = null;
    this.reportar(this.estadoAtual());
  }

  reportar(visivel) {
    // Só avisa quando muda, para não inundar o WebSocket a cada foco/desfoco.
    if (visivel === this.ultimoEnviado) return;
    this.ultimoEnviado = visivel;
    this.enviar({ type: 'PRESENCE', payload: { visible: visivel } });
  }

  /** Liga os eventos do navegador. Devolve uma função para desligar. */
  observar(janela = window) {
    const perdeuFoco = () => this.aoPerderFoco();
    const ganhouFoco = () => this.aoGanharFoco();
    const mudouVisibilidade = () => this.aoMudarVisibilidade();
    // pagehide cobre o caso de fechar a aba ou navegar para fora.
    const saiuDaPagina = () => this.reportar(false);

    janela.addEventListener('blur', perdeuFoco);
    janela.addEventListener('focus', ganhouFoco);
    janela.addEventListener('pagehide', saiuDaPagina);
    this.doc.addEventListener('visibilitychange', mudouVisibilidade);

    return () => {
      janela.removeEventListener('blur', perdeuFoco);
      janela.removeEventListener('focus', ganhouFoco);
      janela.removeEventListener('pagehide', saiuDaPagina);
      this.doc.removeEventListener('visibilitychange', mudouVisibilidade);
    };
  }
}
