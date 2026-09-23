import { SocketClient } from './socket-client.js';
import { UIController } from './ui-controller.js';
import { ChatManager } from './chat-manager.js';
import { EntryGate } from './entry-gate.js';
import { PresenceReporter } from './presence-reporter.js';
import { FilesList } from './files-list.js';
import { MaoLevantada } from './raise-hand.js';
import { ManterTelaAcesa } from './manter-tela-acesa.js';

/** Exportada para que o despachante de mensagens possa ser exercitado pelos testes. */
export class AulaCastApp {
  /**
   * @param {{ criarVigia?: Function, telaAcesa?: object }} opcoes dublês para os testes
   */
  constructor({ criarVigia, telaAcesa } = {}) {
    this.ui = new UIController({ criarVigia });
    this.identidade = null;

    this.retryConnectionBtn = document.getElementById('retryConnectionBtn');

    this.chatManager = new ChatManager(
      (data) => this.socket.send(data),
      () => (this.identidade ? this.identidade.name : 'Aluno')
    );
    // O chat escondido não rola: ao aparecer, vai para a mensagem mais recente.
    this.ui.aoMostrarArea = (area) => {
      if (area === 'chat') this.chatManager.rolarParaOFim();
    };

    this.socket = new SocketClient(
      (state, attempts) => this.handleStateChange(state, attempts),
      (data) => this.handleServerMessage(data)
    );

    this.presence = new PresenceReporter((mensagem) => this.socket.send(mensagem));

    this.mao = new MaoLevantada(
      document.getElementById('raiseHandBtn'),
      (mensagem) => this.socket.send(mensagem)
    );

    this.files = new FilesList({ onNovidade: (novos) => this.avisarArquivosNovos(novos) });

    // A turma relatou a tela "apagando" durante a aula: o monitor ou o celular dormem
    // porque ninguém mexe neles. Quem mantém a tela acesa é este módulo.
    this.telaAcesa = telaAcesa || new ManterTelaAcesa();

    this.entryGate = new EntryGate({
      onIdentified: (identidade, detalhes) => this.entrarNaAula(identidade, detalhes)
    });

    this.bindEvents();

    // Só conecta depois de identificado — a aula não aparece para quem não se apresentou.
    this.entryGate.tentarEntrarComIdentidadeSalva();
  }

  entrarNaAula(identidade, { porGesto = false } = {}) {
    this.identidade = identidade;
    this.ui.setStudentName(identidade.name);

    // O navegador só deixa manter a tela acesa a partir de um gesto do usuário. No envio
    // do formulário há um; quem entra sozinho (identidade salva) ativa no primeiro toque.
    if (porGesto) {
      this.telaAcesa.ativar();
    } else {
      this.telaAcesa.instalarNoPrimeiroGesto();
    }

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
    // Reconectar cria uma conexão nova no servidor: é preciso reenviar a presença e, se
    // estava levantada, a mão. Depois do IDENTIFY, porque o servidor só aceita a mão de
    // quem já tem nome validado.
    this.presence.sincronizar();
    this.mao.reenviarSeLevantada();
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
        // A fixada que já estava lá não é novidade: não conta no botão do chat.
        this.chatManager.fixar(data.payload ? data.payload.pinned : null);
        break;

      // O professor compartilhou (ou tirou) um arquivo.
      case 'FILES':
        this.files.render(data.payload && data.payload.files);
        break;

      case 'CHAT_STATE':
        this.chatManager.setEnabled(data.payload.enabled === 'true');
        break;

      // O professor fixou (ou trocou, ou tirou) a mensagem do topo do chat.
      case 'CHAT_PINNED':
        if (this.chatManager.fixar(data.payload ? data.payload.text : null)) {
          this.ui.marcarNovidade('chat');
        }
        break;

      case 'RAISE_HAND_ACK':
        this.mao.confirmar(data.payload && data.payload.active);
        break;

      case 'HAND_LOWERED':
        if (this.mao.abaixadaPeloProfessor()) this.chatManager.mostrarMaoAbaixada();
        break;

      case 'IDENTIFY_REJECTED':
        this.entryGate.reabrirComErro(data.payload && data.payload.reason);
        break;

      case 'CHAT_MESSAGE':
        this.chatManager.appendMessage(data.payload.sender, data.payload.text, data.payload.isProf);
        // Resposta do professor com o chat fechado: o contador no botão avisa.
        if (data.payload.isProf) this.ui.marcarNovidade('chat');
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

  /** Com Arquivos fechado, o contador no botão avisa que chegou arquivo. */
  avisarArquivosNovos(novos) {
    this.ui.marcarNovidade('arquivos', novos.length);
    this.chatManager.mostrarArquivosNovos(novos);
  }

  /**
   * Quem entra (ou reconecta) precisa ver a aula no estado em que ela está.
   *
   * Antes a conexão só trazia o estado do chat: com a aula pausada ou encerrada, quem
   * reconectava via o último quadro congelado como se fosse ao vivo, e o aviso de pausa
   * de antes da queda podia ficar preso na tela depois de o professor já ter retomado.
   */
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
