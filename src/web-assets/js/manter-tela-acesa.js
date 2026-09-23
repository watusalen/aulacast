import { webm, mp4 } from './vendor/nosleep-media.js';

const GESTOS = ['pointerdown', 'keydown', 'touchend'];

/**
 * Impede que o monitor do laboratório, o celular ou o tablet do aluno apague por economia
 * de energia no meio da aula.
 *
 * O caminho oficial é a Screen Wake Lock API, mas `navigator.wakeLock` só existe em
 * contexto seguro, e a página do aluno é servida por http:// num IP da rede local. Ela só
 * é usada quando existe (localhost, ou um dia com https); no resto, o truque do
 * NoSleep.js (Rich Tibbett, MIT): tocar em laço um vídeo minúsculo e silencioso, que o
 * navegador trata como "alguém assistindo" e por isso segura a tela.
 *
 * Medido no Mac (macOS 26.6.2), lendo `pmset -g assertions` com a página aberta num IP da
 * rede local (192.168.x.x, `isSecureContext === false`, sem `navigator.wakeLock`):
 *
 * Chrome 153 (janela visível, o toque simulado pelo CDP):
 * - vídeo tocando e com som ligado -> `NoDisplaySleepAssertion "Video Wake Lock"`, contínua
 *   (amostrada a cada 100 ms por 3 s, sem buraco), com o vídeo fora do DOM, fora da tela
 *   (left/top -100%), com 1 px, com opacidade 0 e até com `display: none`;
 * - com `muted` ou com `volume = 0`: NENHUMA asserção, em qualquer tamanho ou posição. É
 *   por isso que o vídeo não é mudo (a trilha de áudio é silêncio) e que `ativar()` tem de
 *   rodar dentro de um gesto: vídeo com som só toca depois de uma interação;
 * - aba escondida: a asserção cai; de volta à aba, volta sozinha, com o vídeo tocando;
 * - com `navigator.wakeLock.request('screen')` (em 127.0.0.1, que é contexto seguro):
 *   `NoDisplaySleepAssertion "Blink Wake Lock"`.
 *
 * WebKit do macOS 26.6.2 (WKWebView, mesmo motor do Safari; o Safari em si não deu para
 * automatizar, porque o safaridriver exige ligar "Permitir automação remota" nos ajustes):
 * - `PreventUserIdleDisplaySleep "com.apple.WebCore: HTMLMediaElement playback"` com o
 *   vídeo no DOM: fora da tela, com 1 px quase transparente, ou visível;
 * - nenhuma asserção com o vídeo fora do DOM, com `display: none` ou com `muted`;
 * - com o webm (menos de 1 s, em laço) a asserção cai e volta a cada volta do laço
 *   (buracos na amostragem de 100 ms); com o mp4 e o salto no `timeupdate` ela fica
 *   contínua. Um buraco desses no momento em que o tempo de inatividade vence apaga a tela.
 *   Por isso o mp4 vem primeiro, e o webm fica para navegador sem H.264.
 *
 * Este módulo, do jeito que está, conferido nos dois: asserção contínua de tela desde o
 * gesto (mp4 escolhido, sem `muted`) e nenhuma depois de `desativar()`. O stream MJPEG,
 * sozinho, só gera no Chrome `NoIdleSleepAssertion "Download in progress"`: segura o Mac
 * acordado, mas deixa o monitor apagar.
 *
 * Custo, Chrome 153 num M4, CPU somada de todos os processos do Chrome em 30 s: 2 a 3 % de
 * um núcleo com a página parada; 6 % com o mp4 tocando; 5 % com o webm. Uns 3 a 4 pontos
 * a mais, que num PC modesto do laboratório devem ficar perto de 10 %.
 */
export class ManterTelaAcesa {
  constructor({ janela = window, documento = document } = {}) {
    this.janela = janela;
    this.documento = documento;
    this.ativo = false;
    this.sentinela = null;
    this.pedindoWakeLock = false;
    this.video = null;
    this.ouvindoGesto = false;

    this.aoMudarVisibilidade = () => this.retomar();
    this.aoGesto = () => {
      this.pararDeOuvirGesto();
      if (this.ativo) {
        this.retomar();
      } else {
        this.ativar();
      }
    };
  }

  /**
   * Passa a manter a tela acesa. Chame dentro de um gesto do aluno (clique, toque, tecla):
   * sem isso o navegador recusa tocar o vídeo com som. Chamar de novo não faz nada.
   */
  ativar() {
    if (this.ativo) return;
    this.ativo = true;
    this.pararDeOuvirGesto();
    // A trava do sistema cai quando o aluno troca de aba ou bloqueia o celular, e o
    // navegador pode pausar o vídeo; ao voltar, é preciso pedir de novo.
    this.documento.addEventListener('visibilitychange', this.aoMudarVisibilidade);

    if (this.temWakeLock()) {
      this.pedirWakeLock();
    } else {
      this.tocarVideo();
    }
  }

  /** Deixa a tela voltar a apagar normalmente. */
  desativar() {
    if (!this.ativo) return;
    this.ativo = false;
    this.pararDeOuvirGesto();
    this.documento.removeEventListener('visibilitychange', this.aoMudarVisibilidade);

    const sentinela = this.sentinela;
    this.sentinela = null;
    if (sentinela) sentinela.release().catch(() => {});

    if (this.video) {
      this.video.pause();
      this.video.remove();
      this.video = null;
    }
  }

  /**
   * Para quando o aluno entra sozinho, com a identidade salva, sem ter tocado em nada:
   * espera a primeira interação (clique, toque ou tecla) e só então ativa.
   */
  instalarNoPrimeiroGesto() {
    if (this.ativo || this.ouvindoGesto) return;
    this.ouvirGesto();
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
      this.pedindoWakeLock = false;
      // Recusado (economia de bateria, página escondida no instante do pedido): o vídeo
      // é a segunda chance. Se o gesto já tiver expirado, ele espera o próximo.
      if (this.ativo && this.documento.visibilityState !== 'hidden') this.tocarVideo();
    });
  }

  /** Cria o vídeo uma vez e o põe para tocar. */
  tocarVideo() {
    if (!this.video) this.video = this.criarVideo();
    const tocando = this.video.play();
    if (tocando && typeof tocando.catch === 'function') {
      // Sem gesto (entrou sozinho e o gesto ainda não veio), o navegador recusa:
      // tenta de novo na primeira interação.
      tocando.catch(() => {
        if (this.ativo) this.ouvirGesto();
      });
    }
  }

  criarVideo() {
    const doc = this.documento;
    const video = doc.createElement('video');
    // Sem `playsinline` o iPhone abre o vídeo em tela cheia.
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.setAttribute('aria-hidden', 'true');
    video.setAttribute('tabindex', '-1');
    video.setAttribute('title', 'Mantém a tela acesa durante a aula');
    // Sem botão de AirPlay/Chromecast para um vídeo que ninguém vê.
    video.disableRemotePlayback = true;
    // NÃO pode ser `muted` nem `volume = 0`: nos dois navegadores medidos, vídeo mudo não
    // segura a tela. A trilha de áudio do arquivo é silêncio.

    // mp4 primeiro: no WebKit o laço do webm solta a trava a cada volta (ver acima).
    for (const [tipo, dados] of [['video/mp4', mp4], ['video/webm', webm]]) {
      const fonte = doc.createElement('source');
      fonte.src = dados;
      fonte.type = tipo;
      video.appendChild(fonte);
    }

    video.addEventListener('loadedmetadata', () => {
      if (video.duration <= 1) {
        // webm: menos de 1 s, basta o laço.
        video.loop = true;
      } else {
        // mp4: voltar para um ponto qualquer do começo antes do fim; é o que mantém o
        // iOS (e o WebKit no Mac) com a trava contínua, sem o "fim" de cada volta.
        video.addEventListener('timeupdate', () => {
          if (video.currentTime > 0.5) video.currentTime = Math.random();
        });
      }
    });

    // No DOM e renderizado: o WebKit ignora vídeo fora do documento ou com
    // `display: none`. Fora da tela, sem ocupar espaço nem criar rolagem.
    Object.assign(video.style, {
      position: 'fixed',
      left: '-100%',
      top: '-100%',
      width: '1px',
      height: '1px',
      pointerEvents: 'none'
    });
    doc.body.appendChild(video);
    return video;
  }

  /** De volta à página: repede a trava ou retoma o vídeo pausado pelo sistema. */
  retomar() {
    if (!this.ativo || this.documento.visibilityState === 'hidden') return;
    if (this.video) {
      if (this.video.paused) this.tocarVideo();
    } else if (this.temWakeLock()) {
      this.pedirWakeLock();
    }
  }

  ouvirGesto() {
    if (this.ouvindoGesto) return;
    this.ouvindoGesto = true;
    for (const evento of GESTOS) {
      this.documento.addEventListener(evento, this.aoGesto, { capture: true, passive: true });
    }
  }

  pararDeOuvirGesto() {
    if (!this.ouvindoGesto) return;
    this.ouvindoGesto = false;
    for (const evento of GESTOS) {
      this.documento.removeEventListener(evento, this.aoGesto, { capture: true });
    }
  }
}
