import { SocketClient } from './socket-client.js';
import { UIController } from './ui-controller.js';
import { ChatManager } from './chat-manager.js';
import { EntryGate } from './entry-gate.js';
import { PresenceReporter } from './presence-reporter.js';
import { DebugPanel } from './debug-panel.js';
import { MetricsReporter } from './metrics-reporter.js';
import { FilesList } from './files-list.js';
import { MaoLevantada } from './raise-hand.js';
import { ManterTelaAcesa } from './manter-tela-acesa.js';
import { VideoStreamPlayer, mediaSourceSuportado } from './video-stream-player.js';

/** Exportada para que o despachante de mensagens possa ser exercitado pelos testes. */
export class AulaCastApp {
  /**
   * @param {{ criarVigia?: Function, telaAcesa?: object }} opcoes dublês para os testes
   */
  constructor({ criarVigia, telaAcesa, criarVideoPlayer } = {}) {
    // H.264/fMP4 em cima do MJPEG existente (ver PLANO-COMPRESSAO-DE-VIDEO.md): decidido uma
    // vez, aqui, com a mesma checagem que `VideoStreamPlayer.start()` vai fazer sozinho — para
    // as duas nunca discordarem sobre qual caminho está de pé.
    //
    // Enquanto o suporte a H.264 for a aposta, o MJPEG fica DESLIGADO desde o início
    // (`mjpegSuprimido`), não só escondido atrás do vídeo: as duas conexões rodando ao mesmo
    // tempo gastariam o dobro da banda que a troca inteira existe para economizar. Só liga o
    // MJPEG de volta se o H.264 desistir de verdade — ver `onFallback` abaixo.
    const videoElementoMP4 = document.getElementById('videoStreamMP4');
    const suporteAH264 = Boolean(videoElementoMP4)
      && mediaSourceSuportado(typeof window !== 'undefined' ? window : undefined);

    /** Depois do fallback para MJPEG, o H.264 não é tentado de novo nesta página (banda dobrada). */
    this.h264Desistiu = false;
    this.ui = new UIController({ criarVigia, mjpegSuprimido: suporteAH264 });
    this.identidade = null;
    /** `DebugPanel`, criado só com o aviso `metricas` do servidor. */
    this.debug = null;

    const criarPlayer = criarVideoPlayer || ((el, opcoes) => new VideoStreamPlayer(el, opcoes));
    this.videoPlayer = videoElementoMP4
      ? criarPlayer(videoElementoMP4, {
          // Mesmo mecanismo que já liga/desliga o "aguardando" e o aviso de reconexão para o
          // MJPEG (`aoMudarEstadoDoVideo`) — o H.264 é só outra fonte do mesmo estado.
          onEstado: (estado) => this.ui.aoMudarEstadoDoVideo(estado),
          onFallback: (motivo) => {
            // Daqui em diante esta página é MJPEG: nenhum caminho volta a ligar o H.264.
            this.h264Desistiu = true;
            console.warn(`Vídeo H.264 indisponível (${motivo}); usando MJPEG.`);
            globalThis.AulaCastDebug?.log('rota', `fallback H.264 -> MJPEG: ${motivo}`);
            globalThis.AulaCastMetricas?.evento('rota', { de: 'H.264', para: 'MJPEG', motivo: String(motivo) });
            this.ui.ativarFallbackMJPEG();
          }
        })
      : null;

    this.retryConnectionBtn = document.getElementById('retryConnectionBtn');

    this.chatManager = new ChatManager(
      (data) => this.socket.send(data),
      () => (this.identidade ? this.identidade.name : 'Aluno'),
      // this.files só existe depois desta linha — a seta só lê a referência quando o
      // aluno de fato clica no aviso, já com a FilesList criada (mesmo padrão do nome
      // acima, lido só na hora de enviar).
      (id) => this.files.marcarBaixado(id)
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

    /** 'live' | 'paused' | 'ended': as métricas só correm com a aula ao vivo. */
    this.estadoDaTransmissao = 'live';
    this.metricas = new MetricsReporter({
      enviar: (mensagem) => this.socket.send(mensagem),
      lerRtt: () => this.socket.rttMs(),
      ativo: () => Boolean(this.identidade) && this.socket.isConnected() && this.estadoDaTransmissao === 'live',
      // Depois do fallback a rota é MJPEG, em que o navegador não mede nada.
      lerEstatisticas: () => (this.videoPlayer && !this.h264Desistiu
        ? this.videoPlayer.estatisticas()
        : { rota: 'MJPEG' })
    });

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
    this.metricas.iniciar();
    this.debug?.aoIdentificar();
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

  /** Painel de depuração: só nasce quando o servidor (build de depuração) liga `metricas`. */
  ativarDebug() {
    if (this.debug) return;
    this.debug = new DebugPanel({ video: document.getElementById('videoStreamMP4') });
    this.debug.ativar();
    this.debug.log('rota', this.videoPlayer
      ? 'rota escolhida: H.264 (/stream.mp4 via MediaSource); MJPEG fica de reserva'
      : 'rota escolhida: MJPEG (/stream); sem MediaSource/H.264 neste navegador');
    if (this.identidade) this.debug.aoIdentificar();
  }

  handleServerMessage(data) {
    if (data.type === 'CONNECTED' && data.payload && data.payload.metricas === 'true') this.ativarDebug();
    // Só o tipo: o conteúdo (chat, nomes) nunca vai para o log de depuração.
    globalThis.AulaCastDebug?.log('srv', data.type);
    switch (data.type) {
      case 'DEBUG_INFO':
        globalThis.AulaCastDebug?.log('servidor', 'DEBUG_INFO', data.payload);
        break;

      // Quem entra no meio da aula precisa saber como o chat está agora, e não só
      // quando o professor mexer no botão da próxima vez.
      case 'CONNECTED':
        // Métricas só existem em build de depuração do servidor: sem o aviso, o módulo fica ocioso.
        this.metricas.definirHabilitado(Boolean(data.payload) && data.payload.metricas === 'true');
        if (this.identidade) this.metricas.iniciar();
        if (this.metricas.habilitado && !this.rotaInformada) {
          this.rotaInformada = true;
          this.metricas.evento('rota', { de: 'inicio', para: this.videoPlayer && !this.h264Desistiu ? 'H.264' : 'MJPEG', motivo: 'escolha inicial' });
        }
        if (data.payload && typeof data.payload.chatEnabled === 'boolean') {
          this.chatManager.setEnabled(data.payload.chatEnabled);
        }
        if (data.payload && typeof data.payload.chatVisibleToClass === 'boolean') {
          this.chatManager.setVisibleToClass(data.payload.chatVisibleToClass);
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

      // O professor ligou ou desligou "alunos veem as mensagens uns dos outros" no meio
      // da aula: o aviso fixo do chat muda na hora, sem esperar a próxima mensagem.
      case 'CHAT_VISIBILITY':
        this.chatManager.setVisibleToClass(data.payload.visible === 'true');
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

      // Tabela da turma (servidor + todos os alunos): só vai para o console do navegador.
      case 'METRICS_TABLE':
        this.metricas.aoReceberTabela(data.payload);
        break;

      case 'IDENTIFY_REJECTED':
        this.entryGate.reabrirComErro(data.payload && data.payload.reason);
        break;

      case 'CHAT_MESSAGE':
        this.chatManager.appendMessage(data.payload.sender, data.payload.text, data.payload.isProf);
        // Resposta do professor, ou mensagem de colega (com o chat visível para a turma
        // ligado), com o chat fechado: o contador no botão avisa. O eco da própria
        // mensagem do aluno não conta — ele já sabe o que escreveu.
        if (!this.chatManager.isOwnMessage(data.payload.sender, data.payload.isProf)) {
          this.ui.marcarNovidade('chat');
        }
        break;

      // O professor começou (ou recomeçou) a transmitir com a gente já conectado.
      // Sem tratar isto, quem recebeu um STREAM_ENDED antes ficava preso no aviso de
      // aula encerrada até recarregar a página.
      case 'STREAM_STARTED':
        this.estadoDaTransmissao = 'live';
        this.ui.showStreaming();
        this.videoPlayer?.definirPausado?.(false);
        this.iniciarH264();
        break;

      // Pausada, o servidor não manda nada: o player não pode ler isso como queda.
      case 'STREAM_PAUSED':
        this.estadoDaTransmissao = 'paused';
        this.ui.showPaused();
        this.videoPlayer?.definirPausado?.(true);
        break;

      case 'STREAM_RESUMED':
        this.estadoDaTransmissao = 'live';
        this.ui.hidePaused();
        this.videoPlayer?.definirPausado?.(false);
        break;

      // A captura do professor caiu (monitor desconectado, permissão revogada, erro do
      // sistema). Sem este aviso o aluno ficaria olhando o último quadro congelado.
      case 'STREAM_ENDED':
        this.estadoDaTransmissao = 'ended';
        this.ui.showStreamEnded(data.payload && data.payload.reason);
        this.videoPlayer?.stop();
        break;
    }
  }

  /** Liga o H.264 — salvo se ele já desistiu nesta página e o MJPEG está de pé. */
  iniciarH264() {
    if (this.h264Desistiu) return;
    this.videoPlayer?.start();
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
    this.estadoDaTransmissao = payload.stream;
    switch (payload.stream) {
      case 'paused':
        this.ui.showStreaming();
        this.ui.showPaused();
        this.videoPlayer?.definirPausado?.(true);
        this.iniciarH264();
        break;
      case 'ended':
        this.ui.showStreamEnded(payload.reason);
        this.videoPlayer?.stop();
        break;
      case 'live':
        this.ui.showStreaming();
        this.videoPlayer?.definirPausado?.(false);
        this.iniciarH264();
        break;
    }
  }
}

document.addEventListener('DOMContentLoaded', () => {
  window.aulaCastApp = new AulaCastApp();
});
