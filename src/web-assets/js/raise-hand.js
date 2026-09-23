/**
 * Levantar a mão: um ícone pequeno ao lado do campo do chat.
 *
 * Voltou a pedido da turma, escondido no chat para não pesar a tela. É um jeito de
 * chamar o professor sem escrever, e por isso vale mesmo com o chat desligado.
 *
 * Protocolo:
 *  - aluno → servidor: RAISE_HAND { active };
 *  - servidor → aluno: RAISE_HAND_ACK { active }, que confirma o estado;
 *  - servidor → aluno: HAND_LOWERED, quando o professor abaixa a mão do aluno.
 *
 * O botão muda na hora do toque (sem esperar a confirmação, que numa rede ruim demora e
 * faria o aluno tocar de novo), e a confirmação do servidor é quem manda no fim.
 */
export class MaoLevantada {
  /**
   * @param {HTMLButtonElement|null} botao
   * @param {(mensagem: object) => boolean} enviar devolve se a mensagem saiu
   */
  constructor(botao, enviar) {
    this.botao = botao;
    this.enviar = enviar;
    this.levantada = false;

    if (this.botao) this.botao.addEventListener('click', () => this.alternar());
    this.desenhar();
  }

  alternar() {
    this.levantada = !this.levantada;
    this.desenhar();
    // Sem conexão a mensagem não sai, mas o estado fica: a mão é estado da conexão, e
    // ao reconectar `reenviarSeLevantada` conta ao servidor.
    this.enviar({ type: 'RAISE_HAND', payload: { active: this.levantada } });
  }

  /** RAISE_HAND_ACK: o servidor diz como a mão ficou. */
  confirmar(ativa) {
    if (typeof ativa !== 'boolean') return;
    this.levantada = ativa;
    this.desenhar();
  }

  /** HAND_LOWERED: o professor abaixou. Devolve se a mão estava levantada. */
  abaixadaPeloProfessor() {
    const estava = this.levantada;
    this.levantada = false;
    this.desenhar();
    return estava;
  }

  /**
   * Reconectar cria uma conexão nova no servidor, que não sabe da mão: é preciso contar
   * de novo, depois do IDENTIFY (o servidor só aceita a mão de quem já se identificou).
   */
  reenviarSeLevantada() {
    if (!this.levantada) return;
    this.enviar({ type: 'RAISE_HAND', payload: { active: true } });
  }

  desenhar() {
    if (!this.botao) return;
    const rotulo = this.levantada ? 'Abaixar a mão' : 'Levantar a mão';
    this.botao.setAttribute('aria-pressed', String(this.levantada));
    this.botao.setAttribute('aria-label', rotulo);
    this.botao.title = rotulo;
  }
}
