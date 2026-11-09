/**
 * Pede ao navegador que a tela do participante não apague durante a transmissão, com a
 * Screen Wake Lock API.
 *
 * `navigator.wakeLock` só existe em contexto seguro (https ou localhost), e a página do
 * participante é servida por http:// num IP da rede local. Nesse caso não há nada a fazer:
 * a tela apaga por inatividade como em qualquer página. Antes havia o truque do NoSleep.js
 * (um vídeo escondido, com som, em laço); saiu porque aparecia como "tocando áudio" na aba,
 * disputava o controle de mídia do aparelho e gastava CPU.
 */
export class ManterTelaAcesa {
  constructor({ janela = window, documento = document } = {}) {
    this.janela = janela;
    this.documento = documento;
    this.ativo = false;
    this.sentinela = null;
    this.pedindoWakeLock = false;

    this.aoMudarVisibilidade = () => this.retomar();
  }

  /** Passa a manter a tela acesa, se o navegador oferecer. Chamar de novo não faz nada. */
  ativar() {
    if (this.ativo) return;
    this.ativo = true;
    // A trava cai quando o participante troca de aba ou bloqueia o aparelho: ao voltar,
    // é preciso pedir de novo.
    this.documento.addEventListener('visibilitychange', this.aoMudarVisibilidade);
    if (this.temWakeLock()) this.pedirWakeLock();
  }

  /** Deixa a tela voltar a apagar normalmente. */
  desativar() {
    if (!this.ativo) return;
    this.ativo = false;
    this.documento.removeEventListener('visibilitychange', this.aoMudarVisibilidade);
    const sentinela = this.sentinela;
    this.sentinela = null;
    if (sentinela) sentinela.release().catch(() => {});
  }

  /** A Wake Lock não exige gesto do usuário: ativa direto (nome mantido para quem já chama). */
  instalarNoPrimeiroGesto() {
    this.ativar();
  }

  temWakeLock() {
    const { janela } = this;
    return Boolean(janela.isSecureContext && janela.navigator && 'wakeLock' in janela.navigator);
  }

  pedirWakeLock() {
    if (this.sentinela || this.pedindoWakeLock) return;
    this.pedindoWakeLock = true;
    this.janela.navigator.wakeLock.request('screen').then((sentinela) => {
      this.pedindoWakeLock = false;
      if (!this.ativo) {
        sentinela.release().catch(() => {});
        return;
      }
      this.sentinela = sentinela;
      // O sistema solta a trava sozinho quando a página some da tela.
      sentinela.addEventListener('release', () => {
        if (this.sentinela === sentinela) this.sentinela = null;
      });
    }, () => {
      // Recusado (economia de bateria, página escondida no instante do pedido): sem trava.
      this.pedindoWakeLock = false;
    });
  }

  /** De volta à página: repede a trava que o sistema soltou. */
  retomar() {
    if (!this.ativo || this.documento.visibilityState === 'hidden') return;
    if (this.temWakeLock()) this.pedirWakeLock();
  }
}
