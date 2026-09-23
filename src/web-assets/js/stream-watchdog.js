import { STREAM_RETRY_BASE_MS, STREAM_RETRY_MAX_MS } from './config.js';

/** Classe do <canvas> que o vigia cria logo depois da <img> para segurar o último quadro. */
export const CLASSE_QUADRO_CONGELADO = 'stream-congelado';

/**
 * Vigia o stream MJPEG do <img>, que é uma conexão HTTP separada do WebSocket, e cuida
 * para que a imagem do aluno não fique vazia enquanto o vídeo reconecta.
 *
 * Sem isto, uma queda só do vídeo (oscilação de Wi-Fi, servidor reiniciado) deixa a
 * imagem congelada para sempre enquanto o selo de status continua dizendo "Conectado",
 * porque nada reatribui o `src`.
 *
 * Só o evento `error` conta como queda.
 *
 * Havia aqui um segundo ouvinte, no `load`, com a ideia de que ele marcaria o fim da
 * resposta multipart. Não marca: pela especificação, o `load` de um multipart dispara
 * assim que a PRIMEIRA parte chega — e é isso que Chrome e Safari fazem (o Firefox vai
 * além e dispara a cada quadro). O resultado era o vigia entender o primeiro quadro como
 * "acabou" e derrubar o stream para reconectar, de novo e de novo, com a espera crescendo
 * até o teto de 10 s. O aluno via a imagem engasgar e piscar em ciclo, sem parar.
 *
 * O fim de transmissão de verdade chega pelo WebSocket (STREAM_ENDED), que é o caminho
 * confiável; a queda só do vídeo continua sendo pega pelo `error`.
 *
 * Medido no Chrome 153 e no WebKit do macOS 26.6.2 (WKWebView), com quadros sintéticos e
 * o pixel central da página amostrado a cada quadro pintado:
 * - Trocar o `src` com o stream no ar NÃO apaga a imagem: o navegador segura o quadro
 *   antigo até o primeiro do novo pedido (vermelho -> verde direto, sem vazio).
 * - O servidor fechar a resposta multipart NÃO dispara evento nenhum, nem `error` nem
 *   `load`, nos dois: a imagem fica parada no último quadro. Quem avisa que o servidor
 *   caiu é o WebSocket; por isso quem usa este vigia chama `congelar()` quando o
 *   WebSocket cai e `start()` quando ele volta.
 * - Trocar o `src` com o servidor fora dispara `error` e a imagem fica VAZIA (Chrome:
 *   fundo da página; WebKit: branco) até o primeiro quadro de uma tentativa que dê certo
 *   — 1 s, 2 s, 4 s... Era a "tela que apaga". `removeAttribute('src')` também esvazia na
 *   hora.
 * - `drawImage` de uma <img> MJPEG da mesma origem funciona nos dois: o canvas recebe o
 *   quadro que está na tela (pixel lido de volta com `getImageData`, sem "tainted").
 *
 * Daí a técnica: antes de trocar o `src` (retomada ou nova tentativa) ou de soltar a
 * conexão (`congelar`), o quadro atual é pintado UMA vez num <canvas> irmão da <img>,
 * que fica por cima até o `load` do primeiro quadro novo. Nenhum trabalho por quadro:
 * o canvas só é tocado nesses momentos, e o `load` a cada quadro do Firefox só lê uma
 * flag. Duas <img> alternadas dariam no mesmo, mas dobrariam o elemento que decodifica
 * o vídeo e exigiriam trocar qual delas o CSS e a tela cheia enxergam.
 *
 * Conferido com este módulo, nos mesmos Chrome e WebKit: `congelar()` + `start()`, com e
 * sem o servidor fora (duas tentativas falhando no meio) e com a tela do professor parada,
 * passam do último quadro direto para o novo, sem nenhum quadro pintado vazio; o jeito
 * antigo (`stop()` ao cair, `start()` ao voltar) deixava a área vazia por 1,5 a 1,9 s.
 */
export class StreamWatchdog {
  /**
   * @param {HTMLImageElement} imgElement
   * @param {{ onRetry?: (tentativa: number, motivo: string) => void,
   *           onEstado?: (estado: 'ao-vivo' | 'reconectando' | 'parado') => void }} opcoes
   */
  constructor(imgElement, { onRetry, onEstado } = {}) {
    this.img = imgElement;
    this.onRetry = onRetry || (() => {});
    this.onEstado = onEstado || (() => {});

    this.streamUrl = `${window.location.protocol}//${window.location.host}/stream`;
    this.wantsStream = false;
    /** Há um pedido de stream no `src` que ainda não falhou. */
    this.conectado = false;
    /** Esperando o primeiro quadro do pedido atual (para tirar o canvas de cima). */
    this.esperandoQuadro = false;
    this.retryTimer = null;
    this.attempts = 0;
    this.estado = 'parado';

    /** <canvas class="stream-congelado" hidden>, irmão logo depois da <img>. */
    this.quadroCongelado = this.criarCanvas();

    this.img.addEventListener('error', () => this.handleInterruption('error'));

    // O `load` vira sinal de sucesso, que é o que ele de fato significa: chegou imagem.
    // Sem isto, o intervalo entre tentativas só crescia — uma queda no começo da aula
    // deixava o aluno esperando 10 s por reconexão pelo resto do tempo, mesmo com a rede
    // já boa fazia tempo.
    this.img.addEventListener('load', () => this.aoChegarQuadro());
  }

  /**
   * Passa a manter o stream vivo, reconectando sozinho enquanto for necessário.
   *
   * Idempotente: com um pedido de stream de pé, não faz nada. Antes, cada chamada trocava
   * o `src`, e a página chamava duas vezes a cada reconexão do WebSocket (ao conectar e ao
   * saber que a aula estava ao vivo) — o vídeo reiniciava à toa. Com uma nova tentativa
   * agendada, tenta já: quem chama `start()` sabe que o servidor está de pé.
   */
  start() {
    this.wantsStream = true;
    if (this.conectado) return;
    this.attempts = 0;
    this.connect();
  }

  /** Encerra o stream de propósito (aula encerrada) e limpa a imagem. */
  stop() {
    this.wantsStream = false;
    this.conectado = false;
    this.esperandoQuadro = false;
    this.clearTimer();
    this.esconderCongelado();
    this.img.removeAttribute('src');
    this.mudarEstado('parado');
  }

  /**
   * Solta a conexão de vídeo, mas deixa o último quadro na tela (o WebSocket caiu: o aluno
   * vê a imagem parada com um aviso, e não uma tela preta). Um `start()` depois retoma e o
   * quadro congelado só sai quando o primeiro quadro novo chega.
   */
  congelar() {
    this.cobrirComUltimoQuadro();
    this.wantsStream = false;
    this.conectado = false;
    this.esperandoQuadro = false;
    this.clearTimer();
    this.img.removeAttribute('src');
    this.mudarEstado('parado');
  }

  connect() {
    if (!this.wantsStream) return;
    this.clearTimer();
    // Troca de `src` com o servidor fora deixa a <img> vazia até dar certo (ver acima).
    this.cobrirComUltimoQuadro();
    this.conectado = true;
    this.esperandoQuadro = true;
    // O parâmetro variável evita que o navegador reaproveite a conexão morta do cache.
    this.img.src = `${this.streamUrl}?t=${Date.now()}`;
  }

  aoChegarQuadro() {
    // No Firefox isto roda a cada quadro: fora a flag, nada de trabalho aqui.
    if (!this.esperandoQuadro || !this.wantsStream) return;
    this.esperandoQuadro = false;
    this.attempts = 0;
    this.esconderCongelado();
    this.mudarEstado('ao-vivo');
  }

  handleInterruption(reason) {
    if (!this.wantsStream) return;
    // Ignora o disparo causado por limpar o src ao parar o stream.
    if (!this.img.getAttribute('src')) return;

    this.conectado = false;
    this.esperandoQuadro = false;
    this.attempts += 1;
    const delay = Math.min(
      STREAM_RETRY_BASE_MS * Math.pow(2, this.attempts - 1),
      STREAM_RETRY_MAX_MS
    );

    this.mudarEstado('reconectando');
    this.onRetry(this.attempts, reason);

    this.clearTimer();
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      this.connect();
    }, delay);
  }

  clearTimer() {
    if (this.retryTimer) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }

  mudarEstado(estado) {
    if (estado === this.estado) return;
    this.estado = estado;
    this.onEstado(estado);
  }

  /** O canvas nasce escondido logo depois da <img>; o CSS dá a ele a mesma caixa. */
  criarCanvas() {
    const doc = this.img.ownerDocument;
    if (!doc || !this.img.parentNode) return null;
    const canvas = doc.createElement('canvas');
    canvas.className = CLASSE_QUADRO_CONGELADO;
    canvas.hidden = true;
    canvas.setAttribute('aria-hidden', 'true');
    this.img.parentNode.insertBefore(canvas, this.img.nextSibling);
    return canvas;
  }

  /**
   * Pinta o quadro que está na <img> no canvas e o mostra por cima.
   *
   * Só se houver quadro de verdade, e só se o canvas não estiver já na tela: nesse caso
   * ele guarda o último quadro bom (a <img> só teria um mais novo depois de um `load`, e o
   * `load` tira o canvas), enquanto a <img> por baixo pode estar vazia ou quebrada.
   */
  cobrirComUltimoQuadro() {
    const canvas = this.quadroCongelado;
    if (!canvas || !canvas.hidden || !this.img.getAttribute('src')) return;
    const largura = this.img.naturalWidth;
    const altura = this.img.naturalHeight;
    if (!this.img.complete || !largura || !altura) return;
    try {
      if (canvas.width !== largura) canvas.width = largura;
      if (canvas.height !== altura) canvas.height = altura;
      canvas.getContext('2d').drawImage(this.img, 0, 0, largura, altura);
      canvas.hidden = false;
      // A <img> por baixo fica vazia (ou, no WebKit, branca com o ícone de imagem
      // quebrada) enquanto não chega quadro novo; nas faixas do `object-fit: contain`
      // isso apareceria em volta do quadro congelado.
      this.img.style.visibility = 'hidden';
    } catch (_) {
      // Sem conseguir pintar, melhor não cobrir a imagem com um canvas vazio.
      canvas.hidden = true;
    }
  }

  esconderCongelado() {
    const canvas = this.quadroCongelado;
    if (!canvas || canvas.hidden) return;
    canvas.hidden = true;
    this.img.style.visibility = '';
    // Solta a memória do quadro (8 MB num 1080p): o canvas só volta a ser usado na
    // próxima troca, e aí é redimensionado de novo.
    canvas.width = 0;
    canvas.height = 0;
  }
}
