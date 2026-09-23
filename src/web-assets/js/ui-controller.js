import { ConnectionState } from './config.js';
import { StreamWatchdog } from './stream-watchdog.js';

/**
 * Abaixo desta largura (ou com pouca altura, o celular deitado) o painel vira folha por
 * cima do vídeo. É o mesmo corte do CSS.
 */
export const LARGURA_DA_GAVETA = '(max-width: 860px), (max-height: 500px)';
const CHAVE_PAINEL_FECHADO = 'aulacast.painelFechado';
const CHAVE_AREA = 'aulacast.areaDoPainel';
/** Os controles da imagem (e, na tela cheia, o cursor) somem depois deste tempo parado. */
const OCIOSIDADE_DOS_CONTROLES_MS = 2500;

/** As áreas do painel: uma de cada vez, como no professor. */
const TITULOS = { chat: 'Chat', arquivos: 'Arquivos' };

/** O que o chip da barra diz em cada estado. */
const TEXTO_DO_ESTADO = {
  'ao-vivo': 'Ao vivo',
  pausada: 'Pausada',
  encerrada: 'Encerrada',
  conectando: 'Conectando…',
  reconectando: 'Reconectando…',
  'sem-conexao': 'Sem conexão'
};

const ICONE_AGUARDANDO = String.fromCodePoint(0xE0DF); // present_to_all
const ICONE_ENCERRADA = String.fromCodePoint(0xEF71); // stop_circle

function ler(chave) {
  try {
    return localStorage.getItem(chave);
  } catch (_) {
    return null;
  }
}

function salvar(chave, valor) {
  try {
    localStorage.setItem(chave, valor);
  } catch (_) {
    // Modo privado ou armazenamento bloqueado: só não lembra na próxima vez.
  }
}

/**
 * A tecla F não pode roubar a letra de quem está escrevendo: campo de texto, área de
 * texto e conteúdo editável ficam com ela.
 */
export function ehCampoDeTexto(alvo) {
  if (!alvo) return false;
  if (alvo.isContentEditable) return true;
  const tag = String(alvo.tagName || '').toUpperCase();
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (tag !== 'INPUT') return false;
  const tipo = String(alvo.type || 'text').toLowerCase();
  return !['button', 'checkbox', 'radio', 'submit', 'reset', 'range', 'color', 'file', 'image'].includes(tipo);
}

/** Aberta pela Tela de Início (iPhone) ou instalada (Android): sem a barra do navegador. */
export function ehModoApp(janela = typeof window !== 'undefined' ? window : null) {
  if (!janela) return false;
  const pelaMidia = typeof janela.matchMedia === 'function'
    && janela.matchMedia('(display-mode: fullscreen), (display-mode: standalone)').matches;
  return Boolean(pelaMidia || (janela.navigator && janela.navigator.standalone === true));
}

export class UIController {
  /**
   * @param {{ criarVigia?: (img: HTMLImageElement, opcoes: object) => object }} opcoes
   *   `criarVigia` existe para os testes trocarem o vigia do vídeo por um dublê.
   */
  constructor({ criarVigia } = {}) {
    this.statusBadge = document.getElementById('connectionStatus');
    this.statusText = this.statusBadge.querySelector('.status-text');
    this.videoStream = document.getElementById('videoStream');
    this.placeholder = document.getElementById('placeholder');
    this.reconnectOverlay = document.getElementById('reconnectOverlay');
    this.reconnectAttemptText = document.getElementById('reconnectAttempt');
    this.disconnectedState = document.getElementById('disconnectedState');
    this.pausedOverlay = document.getElementById('pausedOverlay');
    this.fullscreenBtn = document.getElementById('fullscreenBtn');
    this.stage = document.getElementById('stage');
    this.controlesDoVideo = document.getElementById('videoControls');
    this.sidebar = document.getElementById('sidebar');
    this.sidebarBackdrop = document.getElementById('sidebarBackdrop');
    this.sidebarCloseBtn = document.getElementById('sidebarCloseBtn');
    this.panelTitle = document.getElementById('panelTitle');
    this.appEl = document.getElementById('app');

    this.botoes = {
      chat: document.getElementById('chatToggleBtn'),
      arquivos: document.getElementById('filesToggleBtn')
    };
    this.contadores = {
      chat: document.getElementById('chatBadge'),
      arquivos: document.getElementById('filesBadge')
    };
    this.areas = {
      chat: document.getElementById('chatArea'),
      arquivos: document.getElementById('filesArea')
    };

    /** Estado da conexão (WebSocket) e da transmissão (o que o professor está fazendo). */
    this.conexao = ConnectionState.CONNECTING;
    this.transmissao = 'ao-vivo';
    /** Já chegou algum quadro desde que o vídeo foi pedido: há o que congelar. */
    this.teveQuadro = false;

    // O vídeo trafega numa conexão separada do WebSocket e precisa do próprio vigia.
    const criar = criarVigia || ((img, opcoes) => new StreamWatchdog(img, opcoes));
    this.streamWatchdog = criar(this.videoStream, {
      onRetry: (attempt, reason) => {
        console.warn(`Stream de vídeo interrompido (${reason}); tentativa ${attempt}.`);
      },
      onEstado: (estado) => this.aoMudarEstadoDoVideo(estado)
    });
    // O `load` de um multipart dispara quando chega o primeiro quadro (Chrome e Safari):
    // é a hora de trocar o "Aguardando transmissão" pela imagem.
    this.videoStream.addEventListener('load', () => this.aoChegarQuadro());

    // Painel: qual área, e se está aberto no computador. Na folha do celular ele sempre
    // começa fechado, para a imagem aparecer primeiro.
    this.area = ler(CHAVE_AREA) === 'arquivos' ? 'arquivos' : 'chat';
    this.painelFechadoNoComputador = ler(CHAVE_PAINEL_FECHADO) === '1';
    this.gavetaAberta = false;
    this.naoLidas = { chat: 0, arquivos: 0 };
    this.areaMostrada = null;
    /** Chamado quando uma área passa a ficar à vista (o chat rola até o fim). */
    this.aoMostrarArea = null;

    this.midiaDaGaveta = typeof window !== 'undefined' && window.matchMedia
      ? window.matchMedia(LARGURA_DA_GAVETA)
      : null;

    for (const area of Object.keys(this.botoes)) {
      if (this.botoes[area]) this.botoes[area].addEventListener('click', () => this.alternarPainel(area));
    }
    // Tocar fora fecha a folha. É o gesto que todo mundo tenta primeiro no celular.
    if (this.sidebarBackdrop) {
      this.sidebarBackdrop.addEventListener('click', () => this.closeSidebar());
    }
    if (this.sidebarCloseBtn) {
      this.sidebarCloseBtn.addEventListener('click', () => this.closeSidebar());
    }
    if (typeof document.addEventListener === 'function') {
      document.addEventListener('keydown', (e) => this.aoApertarTecla(e));
      document.addEventListener('fullscreenchange', () => this.atualizarBotaoDeTelaCheia());
      document.addEventListener('webkitfullscreenchange', () => this.atualizarBotaoDeTelaCheia());
    }
    // Girar o tablet (ou redimensionar a janela) troca de folha para coluna e vice-versa.
    if (this.midiaDaGaveta && this.midiaDaGaveta.addEventListener) {
      this.midiaDaGaveta.addEventListener('change', () => this.aplicarLayoutDoPainel());
    }

    this.configurarTelaCheia();
    this.aplicarLayoutDoPainel();
    this.atualizarChip();
  }

  // MARK: - Conexão e transmissão

  updateState(state, attempts = 0) {
    this.conexao = state;

    switch (state) {
      case ConnectionState.CONNECTED:
        this.reconnectOverlay.hidden = true;
        this.disconnectedState.hidden = true;
        // O aviso de pausa também sai: se o professor retomou enquanto o aluno estava sem
        // conexão, o STREAM_RESUMED se perdeu. Quem diz como a aula está agora é a
        // mensagem de boas-vindas (CONNECTED), que chega logo depois.
        this.hidePaused();
        if (this.transmissao !== 'encerrada') this.iniciarVideo();
        break;

      case ConnectionState.CONNECTING:
      case ConnectionState.RECONNECTING:
        this.disconnectedState.hidden = true;
        this.hidePaused();
        // Na primeira conexão não há quadro: fica o "Aguardando transmissão". Depois de
        // ter havido imagem, ela fica parada na tela com o aviso pequeno por cima.
        if (state === ConnectionState.RECONNECTING || this.teveQuadro) {
          this.showReconnecting(attempts);
        }
        break;

      case ConnectionState.DISCONNECTED:
        this.reconnectOverlay.hidden = true;
        this.hidePaused();
        this.disconnectedState.hidden = false;
        this.congelarVideo();
        break;
    }
    this.atualizarChip();
  }

  /**
   * Reconectando: congela o último quadro e põe só um chip por cima. Antes a imagem era
   * escondida atrás de uma tela escura a cada oscilação da rede, e a turma via a aula
   * "apagar e piscar".
   */
  showReconnecting(attempts) {
    this.reconnectAttemptText.textContent = attempts > 1 ? `tentativa ${attempts}` : '';
    this.reconnectOverlay.hidden = false;
    this.congelarVideo();
  }

  congelarVideo() {
    this.streamWatchdog.congelar();
  }

  /** Pede o vídeo; enquanto não chega o primeiro quadro, o palco diz que está aguardando. */
  iniciarVideo() {
    this.videoStream.classList.add('active');
    this.streamWatchdog.start();
    if (!this.teveQuadro) this.mostrarAguardando();
  }

  aoChegarQuadro() {
    this.teveQuadro = true;
    if (this.transmissao !== 'encerrada') this.placeholder.hidden = true;
    // Só o vídeo tinha caído (o WebSocket seguiu de pé): o aviso sai com a imagem de volta.
    if (this.conexao === ConnectionState.CONNECTED) this.reconnectOverlay.hidden = true;
    this.atualizarChip();
  }

  /** Estado do vigia do vídeo, que é uma conexão separada do WebSocket. */
  aoMudarEstadoDoVideo(estado) {
    if (estado === 'ao-vivo') {
      this.aoChegarQuadro();
    } else if (estado === 'reconectando') {
      // Só o vídeo caiu. Pausada ou encerrada, a falta de quadros é esperada.
      if (this.conexao === ConnectionState.CONNECTED && this.transmissao === 'ao-vivo' && this.teveQuadro) {
        this.reconnectAttemptText.textContent = '';
        this.reconnectOverlay.hidden = false;
      }
    }
  }

  mostrarAguardando() {
    this.definirPalcoVazio(ICONE_AGUARDANDO, 'Aguardando transmissão',
      'A tela do professor aparecerá aqui automaticamente.', true);
  }

  /** Mantido com o nome antigo: é o palco vazio de "aguardando". */
  showPlaceholder() {
    this.mostrarAguardando();
  }

  definirPalcoVazio(icone, titulo, subtitulo, comProgresso) {
    const iconeEl = this.placeholder.querySelector('.placeholder-icon');
    if (iconeEl) iconeEl.textContent = icone;
    this.placeholder.querySelector('.placeholder-title').textContent = titulo;
    this.placeholder.querySelector('.placeholder-sub').textContent = subtitulo;
    const progresso = this.placeholder.querySelector('.spinner');
    // Pelo atributo, e não por `.hidden`: o indicador é um <svg>, e SVGElement não tem a
    // propriedade `hidden` (atribuí-la cria só um campo JS, e o giro continuava na tela).
    if (progresso) {
      if (comProgresso) progresso.removeAttribute('hidden');
      else progresso.setAttribute('hidden', '');
    }
    this.placeholder.hidden = false;
  }

  /** A transmissão terminou do lado do professor: congelar não ajuda, é preciso dizer o motivo. */
  showStreamEnded(reason) {
    this.transmissao = 'encerrada';
    this.reconnectOverlay.hidden = true;
    this.pausedOverlay.hidden = true;
    this.streamWatchdog.stop();
    this.videoStream.classList.remove('active');
    this.teveQuadro = false;
    this.definirPalcoVazio(ICONE_ENCERRADA, 'Transmissão encerrada',
      reason || 'O professor encerrou a transmissão.', false);
    this.atualizarChip();
  }

  /**
   * A transmissão voltou sem que o WebSocket tenha caído.
   *
   * Depois de um `showStreamEnded` o vigia do vídeo está parado e o palco vazio ocupa a
   * tela. Como a conexão continuou de pé o tempo todo, nada disparava `updateState` de
   * novo: o aluno ficava olhando "Transmissão encerrada" com a aula já rolando.
   */
  showStreaming() {
    this.transmissao = 'ao-vivo';
    this.pausedOverlay.hidden = true;
    if (this.conexao === ConnectionState.CONNECTED) this.reconnectOverlay.hidden = true;
    this.iniciarVideo();
    this.atualizarChip();
  }

  showPaused() {
    this.transmissao = 'pausada';
    this.pausedOverlay.hidden = false;
    if (this.conexao === ConnectionState.CONNECTED) this.reconnectOverlay.hidden = true;
    this.atualizarChip();
  }

  hidePaused() {
    if (this.transmissao === 'pausada') this.transmissao = 'ao-vivo';
    this.pausedOverlay.hidden = true;
    this.atualizarChip();
  }

  hideAllOverlays() {
    this.placeholder.hidden = true;
    this.reconnectOverlay.hidden = true;
    this.disconnectedState.hidden = true;
    this.hidePaused();
  }

  /** O chip junta as duas coisas: sem conexão, é isso que importa; conectado, a aula. */
  estadoDoChip() {
    switch (this.conexao) {
      case ConnectionState.RECONNECTING:
        return 'reconectando';
      case ConnectionState.DISCONNECTED:
        return 'sem-conexao';
      case ConnectionState.CONNECTING:
        return this.teveQuadro ? 'reconectando' : 'conectando';
    }
    if (this.transmissao === 'pausada') return 'pausada';
    if (this.transmissao === 'encerrada') return 'encerrada';
    return 'ao-vivo';
  }

  atualizarChip() {
    if (!this.statusBadge) return;
    const estado = this.estadoDoChip();
    this.statusBadge.className = `chip-estado ${estado}`;
    this.statusText.textContent = TEXTO_DO_ESTADO[estado];
    // No celular deitado o chip vira só o ponto: a dica guarda o texto.
    this.statusBadge.title = TEXTO_DO_ESTADO[estado];
  }

  /// Mostra para o aluno com qual identidade ele entrou na aula.
  setStudentName(name) {
    const alvo = document.getElementById('studentBadge');
    if (alvo && name) {
      alvo.textContent = name;
      alvo.hidden = false;
    }
  }

  // MARK: - Painel (Chat OU Arquivos)

  /** Tela estreita ou baixa: o painel é folha por cima do vídeo. Sem `matchMedia`, idem. */
  ehGaveta() {
    return this.midiaDaGaveta ? this.midiaDaGaveta.matches : true;
  }

  painelVisivel() {
    return this.ehGaveta() ? this.gavetaAberta : !this.painelFechadoNoComputador;
  }

  areaVisivel(area) {
    return this.painelVisivel() && this.area === area;
  }

  /** Abre a área pedida; se ela já é a que está aberta, fecha o painel (como no Meet). */
  alternarPainel(area) {
    if (this.areaVisivel(area)) {
      this.closeSidebar();
    } else {
      this.openSidebar(area);
    }
  }

  /** Mantém o nome antigo sem argumento: alterna a área atual. */
  toggleSidebar() {
    this.alternarPainel(this.area);
  }

  openSidebar(area = this.area) {
    this.area = area === 'arquivos' ? 'arquivos' : 'chat';
    salvar(CHAVE_AREA, this.area);
    if (this.ehGaveta()) {
      this.gavetaAberta = true;
    } else {
      this.painelFechadoNoComputador = false;
      salvar(CHAVE_PAINEL_FECHADO, '0');
    }
    this.aplicarLayoutDoPainel();
    // Na folha, o foco entra nela: quem usa teclado ou leitor de tela sabe onde está.
    if (this.ehGaveta()) this.focar(this.sidebarCloseBtn);
  }

  closeSidebar() {
    const eraGaveta = this.ehGaveta() && this.gavetaAberta;
    if (this.ehGaveta()) {
      this.gavetaAberta = false;
    } else {
      this.painelFechadoNoComputador = true;
      salvar(CHAVE_PAINEL_FECHADO, '1');
    }
    this.aplicarLayoutDoPainel();
    // E volta para o botão que a abriu, em vez de se perder no começo da página.
    if (eraGaveta) this.focar(this.botoes[this.area]);
  }

  focar(elemento) {
    if (elemento && typeof elemento.focus === 'function') elemento.focus({ preventScroll: true });
  }

  /** Deixa classes, botões e contadores de acordo com o estado atual do painel. */
  aplicarLayoutDoPainel() {
    const gaveta = this.ehGaveta();
    if (!gaveta) {
      // Ao virar coluna, a folha aberta não pode ficar por cima de tudo.
      this.gavetaAberta = false;
    }
    this.sidebar.classList[gaveta && this.gavetaAberta ? 'add' : 'remove']('open');
    this.atualizarFundoDaGaveta(gaveta && this.gavetaAberta);
    if (this.appEl) {
      this.appEl.classList[!gaveta && this.painelFechadoNoComputador ? 'add' : 'remove']('painel-fechado');
    }

    for (const area of Object.keys(this.areas)) {
      if (this.areas[area]) this.areas[area].hidden = area !== this.area;
    }
    if (this.panelTitle) this.panelTitle.textContent = TITULOS[this.area];

    const visivel = this.painelVisivel();
    if (visivel) this.naoLidas[this.area] = 0;
    for (const area of Object.keys(this.botoes)) {
      this.desenharBotao(area);
      this.atualizarContador(area);
    }

    // A área acabou de aparecer: o chat escondido não rola, então rola agora.
    const mostrada = visivel ? this.area : null;
    if (mostrada !== this.areaMostrada) {
      this.areaMostrada = mostrada;
      if (mostrada && typeof this.aoMostrarArea === 'function') this.aoMostrarArea(mostrada);
    }
  }

  /** O botão do painel aberto fica preenchido, com o shape morph do M3. */
  desenharBotao(area) {
    const botao = this.botoes[area];
    if (!botao) return;
    const aberta = this.areaVisivel(area);
    botao.classList[aberta ? 'add' : 'remove']('selecionado');
    botao.setAttribute('aria-expanded', String(aberta));
    const n = this.naoLidas[area];
    const rotulo = n > 0
      ? `${TITULOS[area]}, ${n} ${n === 1 ? 'novidade' : 'novidades'}`
      : TITULOS[area];
    botao.setAttribute('aria-label', rotulo);
    botao.title = aberta ? `Fechar ${TITULOS[area].toLowerCase()}` : TITULOS[area];
  }

  /**
   * Conta o que chega com a área fechada: mensagens do professor e fixadas no Chat,
   * arquivos novos em Arquivos.
   */
  marcarNovidade(area = 'chat', quantidade = 1) {
    if (this.areaVisivel(area)) return;
    this.naoLidas[area] += quantidade;
    this.atualizarContador(area);
    this.desenharBotao(area);
  }

  zerarNaoLidas(area = this.area) {
    this.naoLidas[area] = 0;
    this.atualizarContador(area);
    this.desenharBotao(area);
  }

  atualizarContador(area) {
    const contador = this.contadores[area];
    if (!contador) return;
    const n = this.naoLidas[area];
    contador.hidden = n === 0;
    contador.textContent = n > 99 ? '99+' : String(n);
  }

  atualizarFundoDaGaveta(aberta) {
    if (!this.sidebarBackdrop) return;
    this.sidebarBackdrop.hidden = !aberta;
    this.sidebarBackdrop.classList[aberta ? 'add' : 'remove']('visible');
  }

  // MARK: - Teclado e tela cheia

  aoApertarTecla(e) {
    if (e.key === 'Escape') {
      if (this.ehGaveta() && this.painelVisivel()) this.closeSidebar();
      return;
    }
    // F entra e sai da tela cheia, como no YouTube. Com Ctrl/Cmd/Alt é atalho de outra
    // coisa (Cmd+F é buscar), e num campo de texto é a letra F.
    if (e.key !== 'f' && e.key !== 'F') return;
    if (e.ctrlKey || e.metaKey || e.altKey || e.repeat || e.isComposing) return;
    if (ehCampoDeTexto(e.target) || ehCampoDeTexto(document.activeElement)) return;
    if (!this.podeTelaCheia) return;
    if (typeof e.preventDefault === 'function') e.preventDefault();
    this.toggleFullscreen();
  }

  /**
   * Tela cheia como a do YouTube: vai para a tela cheia só o palco (a imagem e os avisos
   * de pausa e reconexão), e a barra e o painel somem. Antes ia a página inteira, como no
   * Meet, e a turma reclamou que a tela "nunca ficava cheia de verdade".
   *
   * O botão fica no canto de baixo à direita da imagem, como nos players, e não na barra:
   * aparece ao mexer o mouse sobre a imagem e some sozinho (na tela cheia, com o cursor).
   * Duplo clique na imagem também entra e sai.
   *
   * O botão some onde não há como: o Safari do iPhone só põe <video> em tela cheia (lá o
   * caminho é "Adicionar à Tela de Início"), e a aula aberta como app em tela cheia já
   * está sem a barra do navegador.
   */
  configurarTelaCheia() {
    this.alvoDaTelaCheia = this.stage || null;
    const alvo = this.alvoDaTelaCheia;
    this.podeTelaCheia = Boolean(alvo && (alvo.requestFullscreen || alvo.webkitRequestFullscreen));
    const jaSemBarra = typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      && window.matchMedia('(display-mode: fullscreen)').matches;
    this.fullscreenBtn.hidden = !this.podeTelaCheia || jaSemBarra;
    if (this.controlesDoVideo) this.controlesDoVideo.hidden = this.fullscreenBtn.hidden;
    this.fullscreenBtn.addEventListener('click', () => this.toggleFullscreen());
    if (alvo && this.podeTelaCheia) {
      alvo.addEventListener('dblclick', (e) => {
        // O duplo clique no próprio botão já é tratado pelo clique.
        if (e && e.target && typeof e.target.closest === 'function' && e.target.closest('button')) return;
        this.toggleFullscreen();
      });
      // Mexer o mouse (ou tocar) mostra os controles por um instante.
      for (const evento of ['pointermove', 'pointerdown']) {
        alvo.addEventListener(evento, () => this.mostrarControlesDoVideo());
      }
      // Fora da tela cheia, o mouse saindo da imagem esconde na hora, como no YouTube.
      alvo.addEventListener('pointerleave', () => {
        if (!this.emTelaCheia()) this.esconderControlesDoVideo();
      });
    }
    this.atualizarBotaoDeTelaCheia();
  }

  emTelaCheia() {
    return Boolean(document.fullscreenElement || document.webkitFullscreenElement);
  }

  atualizarBotaoDeTelaCheia() {
    const cheia = this.emTelaCheia();
    const rotulo = cheia ? 'Sair da tela cheia (F)' : 'Tela cheia (F)';
    this.fullscreenBtn.setAttribute('aria-pressed', String(cheia));
    this.fullscreenBtn.setAttribute('aria-label', rotulo);
    this.fullscreenBtn.title = rotulo;
    // Ao entrar e ao sair, os controles aparecem por um instante: o aluno vê onde sair.
    this.mostrarControlesDoVideo();
  }

  /** Mostra os controles e, sem movimento por 2,5 s, esconde (na tela cheia, o cursor também). */
  mostrarControlesDoVideo() {
    if (!this.stage) return;
    this.stage.classList.remove('ocioso');
    this.limparOciosidade();
    this.timerDeOciosidade = setTimeout(() => {
      this.timerDeOciosidade = null;
      this.esconderControlesDoVideo();
    }, OCIOSIDADE_DOS_CONTROLES_MS);
    // O timer não pode segurar o processo aberto nos testes (Node).
    if (this.timerDeOciosidade && typeof this.timerDeOciosidade.unref === 'function') {
      this.timerDeOciosidade.unref();
    }
  }

  esconderControlesDoVideo() {
    this.limparOciosidade();
    if (this.stage) this.stage.classList.add('ocioso');
  }

  limparOciosidade() {
    if (this.timerDeOciosidade) {
      clearTimeout(this.timerDeOciosidade);
      this.timerDeOciosidade = null;
    }
  }

  toggleFullscreen() {
    if (!this.emTelaCheia()) {
      const alvo = this.alvoDaTelaCheia;
      const entrar = alvo && (alvo.requestFullscreen || alvo.webkitRequestFullscreen);
      if (!entrar) return;
      const resultado = entrar.call(alvo);
      if (resultado && resultado.catch) {
        resultado.catch((err) => console.error('Erro ao entrar em tela cheia:', err));
      }
    } else {
      const sair = document.exitFullscreen || document.webkitExitFullscreen;
      if (sair) sair.call(document);
    }
  }
}
