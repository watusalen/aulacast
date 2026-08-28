import { SocketClient } from './socket-client.js';
import { UIController } from './ui-controller.js';
import { ChatManager } from './chat-manager.js';
import { EntryGate } from './entry-gate.js';
import { PresenceReporter } from './presence-reporter.js';

/** Exportada para que o despachante de mensagens possa ser exercitado pelos testes. */
export class AulaCastApp {
  constructor() {
    this.ui = new UIController();
    this.isHandRaised = false;
    this.identidade = null;

    this.raiseHandBtn = document.getElementById('raiseHandBtn');
    this.handText = document.getElementById('handText');
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
    } else {
      this.socket.connect();
    }
  }

  enviarIdentificacao() {
    if (!this.identidade) return;
    this.socket.send({
      type: 'IDENTIFY',
      payload: { name: this.identidade.name, matricula: this.identidade.matricula }
    });
    // Reconectar cria uma conexão nova no servidor: é preciso reenviar a presença.
    this.presence.sincronizar();
  }

  bindEvents() {
    this.raiseHandBtn.addEventListener('click', () => this.toggleHandRaise());
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

      case 'RAISE_HAND_ACK':
        this.isHandRaised = data.payload.active;
        this.updateRaiseHandUI();
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

  toggleHandRaise() {
    if (!this.identidade) return;
    this.isHandRaised = !this.isHandRaised;

    this.socket.send({
      type: 'RAISE_HAND',
      payload: { studentName: this.identidade.name, active: this.isHandRaised }
    });

    this.updateRaiseHandUI();
  }

  updateRaiseHandUI() {
    this.ui.setHandRaised(this.isHandRaised);

    if (this.isHandRaised) {
      this.raiseHandBtn.classList.add('raised');
      this.raiseHandBtn.setAttribute('aria-pressed', 'true');
      this.handText.textContent = 'Mão Levantada';
    } else {
      this.raiseHandBtn.classList.remove('raised');
      this.raiseHandBtn.setAttribute('aria-pressed', 'false');
      this.handText.textContent = 'Levantar a Mão';
    }
  }
}

document.addEventListener('DOMContentLoaded', () => {
  window.aulaCastApp = new AulaCastApp();
});
