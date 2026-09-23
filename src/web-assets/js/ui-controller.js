import { ConnectionState } from './config.js';
import { StreamWatchdog } from './stream-watchdog.js';

/** Abaixo desta largura o painel vira gaveta por cima do vídeo (mesmo corte do CSS). */
const LARGURA_DA_GAVETA = '(max-width: 860px)';
const CHAVE_PAINEL_FECHADO = 'aulacast.painelFechado';

/** Preferência do aluno no computador; sem armazenamento, o painel começa aberto. */
function lerPainelFechado() {
  try {
    return localStorage.getItem(CHAVE_PAINEL_FECHADO) === '1';
  } catch (_) {
    return false;
  }
}

function salvarPainelFechado(fechado) {
  try {
    localStorage.setItem(CHAVE_PAINEL_FECHADO, fechado ? '1' : '0');
  } catch (_) {
    // Modo privado ou armazenamento bloqueado: só não lembra na próxima vez.
  }
}

export class UIController {
  constructor() {
    this.statusBadge = document.getElementById('connectionStatus');
    this.statusText = this.statusBadge.querySelector('.status-text');
    this.videoStream = document.getElementById('videoStream');
    this.videoWrap = this.videoStream.closest('.video-wrap');
    this.placeholder = document.getElementById('placeholder');
    this.reconnectOverlay = document.getElementById('reconnectOverlay');
    this.reconnectAttemptText = document.getElementById('reconnectAttempt');
    this.disconnectedState = document.getElementById('disconnectedState');
    this.pausedOverlay = document.getElementById('pausedOverlay');
    this.fullscreenBtn = document.getElementById('fullscreenBtn');
    this.sidebar = document.getElementById('sidebar');
    this.menuToggleBtn = document.getElementById('menuToggleBtn');

    // O vídeo trafega numa conexão separada do WebSocket e precisa do próprio vigia.
    this.streamWatchdog = new StreamWatchdog(this.videoStream, {
      onRetry: (attempt, reason) => {
        console.warn(`Stream de vídeo interrompido (${reason}); tentativa ${attempt}.`);
      }
    });

    this.sidebarBackdrop = document.getElementById('sidebarBackdrop');
    this.appEl = document.getElementById('app');
    this.sidebarCloseBtn = document.getElementById('sidebarCloseBtn');
    this.panelBadge = document.getElementById('panelBadge');
    this.naoLidas = 0;
    this.painelFechadoNoComputador = lerPainelFechado();
    this.midiaDaGaveta = typeof window !== 'undefined' && window.matchMedia
      ? window.matchMedia(LARGURA_DA_GAVETA)
      : null;

    // iPhone não põe elemento em tela cheia, e Safari antigo só tem a versão webkit.
    // Chamar a função que não existe lançava erro e o botão simplesmente não fazia nada.
    if (!this.videoWrap.requestFullscreen && !this.videoWrap.webkitRequestFullscreen) {
      this.fullscreenBtn.hidden = true;
    }
    this.fullscreenBtn.addEventListener('click', () => this.toggleFullscreen());
    this.menuToggleBtn.addEventListener('click', () => this.toggleSidebar());

    // Tocar fora fecha a conversa. É o gesto que todo mundo tenta primeiro no
    // celular; sem ele, a gaveta só fechava voltando no mesmo botão que a abriu.
    if (this.sidebarBackdrop) {
      this.sidebarBackdrop.addEventListener('click', () => this.closeSidebar());
    }
    if (this.sidebarCloseBtn) {
      this.sidebarCloseBtn.addEventListener('click', () => this.closeSidebar());
    }
    // Esc fecha a gaveta no celular/tablet com teclado.
    if (typeof document.addEventListener === 'function') {
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && this.ehGaveta() && this.painelVisivel()) this.closeSidebar();
      });
    }
    // Girar o tablet (ou redimensionar a janela) troca de gaveta para coluna e vice-versa.
    if (this.midiaDaGaveta && this.midiaDaGaveta.addEventListener) {
      this.midiaDaGaveta.addEventListener('change', () => this.aplicarLayoutDoPainel());
    }
    this.aplicarLayoutDoPainel();
  }

  updateState(state, attempts = 0) {
    this.statusBadge.className = `badge ${state}`;

    switch (state) {
      case ConnectionState.CONNECTED:
        this.statusText.textContent = 'Conectado';
        this.hideAllOverlays();
        this.videoStream.classList.add('active');
        this.streamWatchdog.start();
        break;
      case ConnectionState.CONNECTING:
        this.statusText.textContent = 'Conectando...';
        this.hideAllOverlays();
        this.showPlaceholder();
        break;
      case ConnectionState.RECONNECTING:
        this.statusText.textContent = 'Reconectando...';
        this.hideAllOverlays();
        this.showReconnecting(attempts);
        break;
      case ConnectionState.DISCONNECTED:
        this.statusText.textContent = 'Desconectado';
        this.hideAllOverlays();
        this.showDisconnected();
        break;
    }
  }

  showPlaceholder() {
    // Restaura o texto padrão: showStreamEnded pode tê-lo trocado numa aula anterior.
    this.placeholder.querySelector('.placeholder-title').textContent = 'Aguardando transmissão';
    this.placeholder.querySelector('.placeholder-sub').textContent =
      'A tela do professor aparecerá aqui automaticamente.';
    const spinner = this.placeholder.querySelector('.spinner');
    if (spinner) spinner.hidden = false;

    this.placeholder.hidden = false;
    this.videoStream.classList.remove('active');
    this.streamWatchdog.stop();
  }

  showReconnecting(attempts) {
    this.reconnectAttemptText.textContent = attempts > 0
      ? `tentativa ${attempts}`
      : 'reconectando';
    this.reconnectOverlay.hidden = false;
    this.videoStream.classList.remove('active');
    this.streamWatchdog.stop();
  }

  showDisconnected() {
    this.disconnectedState.hidden = false;
    this.videoStream.classList.remove('active');
    this.streamWatchdog.stop();
  }

  /** A transmissão terminou do lado do professor: congelar não ajuda, é preciso dizer o motivo. */
  showStreamEnded(reason) {
    this.hideAllOverlays();
    this.hidePaused();
    this.streamWatchdog.stop();
    this.videoStream.classList.remove('active');

    this.placeholder.hidden = false;
    this.placeholder.querySelector('.placeholder-title').textContent = 'Transmissão encerrada';
    this.placeholder.querySelector('.placeholder-sub').textContent =
      reason || 'O professor encerrou a transmissão.';
    const spinner = this.placeholder.querySelector('.spinner');
    if (spinner) spinner.hidden = true;
  }

  /**
   * A transmissão voltou sem que o WebSocket tenha caído.
   *
   * Depois de um `showStreamEnded` o vigia do vídeo está parado e o placeholder ocupa a
   * tela. Como a conexão continuou de pé o tempo todo, nada disparava `updateState` de
   * novo: o aluno ficava olhando "Transmissão encerrada" com a aula já rolando.
   */
  showStreaming() {
    this.hideAllOverlays();
    this.hidePaused();
    this.videoStream.classList.add('active');
    this.streamWatchdog.start();
  }

  showPaused() {
    this.pausedOverlay.hidden = false;
  }

  hidePaused() {
    this.pausedOverlay.hidden = true;
  }

  hideAllOverlays() {
    this.placeholder.hidden = true;
    this.reconnectOverlay.hidden = true;
    this.disconnectedState.hidden = true;
    // O aviso de pausa também: se o professor retomou enquanto o aluno estava sem
    // conexão, o STREAM_RESUMED se perdeu e o aviso ficava por cima do vídeo ao vivo.
    // Quem diz se a aula está pausada agora é a mensagem de boas-vindas.
    this.hidePaused();
  }

  /// Mostra para o aluno com qual identidade ele entrou na aula.
  setStudentName(name) {
    const alvo = document.getElementById('studentBadge');
    if (alvo && name) {
      alvo.textContent = name;
      alvo.hidden = false;
    }
  }

  /** Tela estreita: o painel é gaveta por cima do vídeo. Sem `matchMedia`, idem. */
  ehGaveta() {
    return this.midiaDaGaveta ? this.midiaDaGaveta.matches : true;
  }

  painelVisivel() {
    return this.ehGaveta()
      ? this.sidebar.classList.contains('open')
      : !this.painelFechadoNoComputador;
  }

  toggleSidebar() {
    if (this.painelVisivel()) {
      this.closeSidebar();
    } else {
      this.openSidebar();
    }
  }

  openSidebar() {
    if (this.ehGaveta()) {
      this.sidebar.classList.add('open');
      this.atualizarFundoDaGaveta(true);
    } else {
      this.painelFechadoNoComputador = false;
      salvarPainelFechado(false);
    }
    this.aplicarLayoutDoPainel();
  }

  closeSidebar() {
    if (this.ehGaveta()) {
      this.sidebar.classList.remove('open');
      this.atualizarFundoDaGaveta(false);
    } else {
      this.painelFechadoNoComputador = true;
      salvarPainelFechado(true);
    }
    this.aplicarLayoutDoPainel();
  }

  /** Deixa classes, botão e contador de acordo com o estado atual do painel. */
  aplicarLayoutDoPainel() {
    const gaveta = this.ehGaveta();
    if (!gaveta) {
      // Ao virar coluna, a gaveta aberta não pode ficar por cima de tudo.
      this.sidebar.classList.remove('open');
      this.atualizarFundoDaGaveta(false);
    }
    if (this.appEl) {
      if (!gaveta && this.painelFechadoNoComputador) {
        this.appEl.classList.add('painel-fechado');
      } else {
        this.appEl.classList.remove('painel-fechado');
      }
    }

    const visivel = this.painelVisivel();
    const rotulo = visivel ? 'Fechar conversa e arquivos' : 'Abrir conversa e arquivos';
    this.menuToggleBtn.setAttribute('aria-expanded', String(visivel));
    this.menuToggleBtn.setAttribute('aria-label', rotulo);
    this.menuToggleBtn.title = rotulo;
    if (visivel) {
      this.menuToggleBtn.classList.add('ativo');
      this.zerarNaoLidas();
    } else {
      this.menuToggleBtn.classList.remove('ativo');
    }
  }

  /** Conta mensagens do professor e arquivos que chegam com o painel fechado. */
  marcarNovidade(quantidade = 1) {
    if (this.painelVisivel()) return;
    this.naoLidas += quantidade;
    this.atualizarContador();
  }

  zerarNaoLidas() {
    this.naoLidas = 0;
    this.atualizarContador();
  }

  atualizarContador() {
    if (!this.panelBadge) return;
    this.panelBadge.hidden = this.naoLidas === 0;
    this.panelBadge.textContent = this.naoLidas > 9 ? '9+' : String(this.naoLidas);
  }

  atualizarFundoDaGaveta(aberta) {
    if (!this.sidebarBackdrop) return;
    this.sidebarBackdrop.hidden = !aberta;
    this.sidebarBackdrop.classList.toggle('visible', aberta);
  }

  toggleFullscreen() {
    // Coloca o container em tela cheia (e não a <img>), para que os controles
    // e os avisos continuem visíveis por cima do vídeo, como no YouTube.
    const emTelaCheia = document.fullscreenElement || document.webkitFullscreenElement;
    if (!emTelaCheia) {
      const entrar = this.videoWrap.requestFullscreen || this.videoWrap.webkitRequestFullscreen;
      if (!entrar) return;
      const resultado = entrar.call(this.videoWrap);
      if (resultado && resultado.catch) {
        resultado.catch(err => console.error('Erro ao entrar em tela cheia:', err));
      }
    } else {
      const sair = document.exitFullscreen || document.webkitExitFullscreen;
      if (sair) sair.call(document);
    }
  }
}
