import { SocketClient } from './socket-client.js';
import { UIController } from './ui-controller.js';
import { ChatManager } from './chat-manager.js';
import { EntryGate } from './entry-gate.js';
import { PresenceReporter } from './presence-reporter.js';
import { FilesList } from './files-list.js';

/** Exportada para que o despachante de mensagens possa ser exercitado pelos testes. */
export class AulaCastApp {
  constructor() {
    this.ui = new UIController();
    this.identidade = null;

    this.retryConnectionBtn = document.getElementById('retryConnectionBtn');

    this.chatManager = new ChatManager(
      (data) => this.socket.send(data),
      () => (this.identidade ? this.identidade.name : 'Aluno')
    );

    this.socket = new SocketClient(
      (state, attempts) => this.handleStateChange(state, attempts),
      (data) => this.handleServerMessage(data)
    );

    this.presence = new PresenceReporter((mensagem) => this.socket.send(mensagem));

    this.files = new FilesList({ onNovidade: (novos) => this.avisarArquivosNovos(novos) });

    this.entryGate = new EntryGate({
      onIdentified: (identidade) => this.entrarNaAula(identidade)
    });

    this.bindEvents();

    // Só conecta depois de identificado — a aula não aparece para quem não se apresentou.
    this.entryGate.tentarEntrarComIdentidadeSalva();
  }

  entrarNaAula(identidade) {
    this.identidade = identidade;
    this.ui.setStudentName(identidade.name);

    if (this.socket.isConnected()) {
      this.enviarIdentificacao();
    } else if (!this.socket.isConnecting()) {
      // `retryNow` e não `connect`: se havia uma tentativa agendada (o aluno reenviou o
      // nome durante a espera), ela é cancelada. Com `connect` ela disparava depois e
      // derrubava a conexão recém-aberta.
      this.socket.retryNow();
    }
  }

  enviarIdentificacao() {
    if (!this.identidade) return;
    this.socket.send({
      type: 'IDENTIFY',
      payload: { name: this.identidade.name }
    });
    // Reconectar cria uma conexão nova no servidor: é preciso reenviar a presença.
    this.presence.sincronizar();
  }

  bindEvents() {
    this.retryConnectionBtn.addEventListener('click', () => this.socket.retryNow());

    // Minimizar, trocar de aba ou clicar em outro app conta como "não está vendo".
    this.presence.observar();
  }

  handleStateChange(state, attempts) {
    this.ui.updateState(state, attempts);

    // Ao (re)conectar é preciso se identificar de novo: para o servidor é uma conexão nova.
    if (state === 'connected') {
      this.enviarIdentificacao();
    }
  }

  handleServerMessage(data) {
    switch (data.type) {
      // Quem entra no meio da aula precisa saber como o chat está agora, e não só
      // quando o professor mexer no botão da próxima vez.
      case 'CONNECTED':
        if (data.payload && typeof data.payload.chatEnabled === 'boolean') {
          this.chatManager.setEnabled(data.payload.chatEnabled);
        }
        this.aplicarEstadoDaTransmissao(data.payload);
        if (data.payload && Array.isArray(data.payload.files)) {
          this.files.render(data.payload.files);
        }
        break;

      // O professor compartilhou (ou tirou) um arquivo.
      case 'FILES':
        this.files.render(data.payload && data.payload.files);
        break;

      case 'CHAT_STATE':
        this.chatManager.setEnabled(data.payload.enabled === 'true');
        break;

      case 'IDENTIFY_REJECTED':
        this.entryGate.reabrirComErro(data.payload && data.payload.reason);
        break;

      case 'CHAT_MESSAGE':
        this.chatManager.appendMessage(data.payload.sender, data.payload.text, data.payload.isProf);
        break;

      // O professor começou (ou recomeçou) a transmitir com a gente já conectado.
      // Sem tratar isto, quem recebeu um STREAM_ENDED antes ficava preso no aviso de
      // aula encerrada até recarregar a página.
      case 'STREAM_STARTED':
        this.ui.showStreaming();
        break;

      case 'STREAM_PAUSED':
        this.ui.showPaused();
        break;

      case 'STREAM_RESUMED':
        this.ui.hidePaused();
        break;

      // A captura do professor caiu (monitor desconectado, permissão revogada, erro do
      // sistema). Sem este aviso o aluno ficaria olhando o último quadro congelado.
      case 'STREAM_ENDED':
        this.ui.showStreamEnded(data.payload && data.payload.reason);
        break;
    }
  }

  /**
   * Quem entra (ou reconecta) precisa ver a aula no estado em que ela está.
   *
   * Antes a conexão só trazia o estado do chat: com a aula pausada ou encerrada, quem
   * reconectava via o último quadro congelado como se fosse ao vivo, e o aviso de pausa
   * de antes da queda podia ficar preso na tela depois de o professor já ter retomado.
   */
  /** No celular a lista fica na gaveta fechada: o ponto no menu avisa que chegou arquivo. */
  avisarArquivosNovos(novos) {
    this.ui.marcarNovidade();
    const nomes = novos.map((a) => a.name).join(', ');
    this.chatManager.mostrarAviso(`O professor compartilhou: ${nomes}`);
  }

  aplicarEstadoDaTransmissao(payload) {
    if (!payload || !payload.stream) return;
    switch (payload.stream) {
      case 'paused':
        this.ui.showStreaming();
        this.ui.showPaused();
        break;
      case 'ended':
        this.ui.showStreamEnded(payload.reason);
        break;
      case 'live':
        this.ui.showStreaming();
        break;
    }
  }
}

document.addEventListener('DOMContentLoaded', () => {
  window.aulaCastApp = new AulaCastApp();
});
