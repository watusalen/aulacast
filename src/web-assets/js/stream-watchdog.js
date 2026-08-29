import { STREAM_RETRY_BASE_MS, STREAM_RETRY_MAX_MS } from './config.js';

/**
 * Vigia o stream MJPEG do <img>, que é uma conexão HTTP separada do WebSocket.
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
 */
export class StreamWatchdog {
  constructor(imgElement, { onRetry } = {}) {
    this.img = imgElement;
    this.onRetry = onRetry || (() => {});

    this.streamUrl = `${window.location.protocol}//${window.location.host}/stream`;
    this.wantsStream = false;
    this.retryTimer = null;
    this.attempts = 0;

    this.img.addEventListener('error', () => this.handleInterruption('error'));

    // O `load` vira sinal de sucesso, que é o que ele de fato significa: chegou imagem.
    // Sem isto, o intervalo entre tentativas só crescia — uma queda no começo da aula
    // deixava o aluno esperando 10 s por reconexão pelo resto do tempo, mesmo com a rede
    // já boa fazia tempo.
    this.img.addEventListener('load', () => { this.attempts = 0; });
  }

  /** Passa a manter o stream vivo, reconectando sozinho enquanto for necessário. */
  start() {
    this.wantsStream = true;
    this.attempts = 0;
    this.connect();
  }

  /** Encerra o stream de propósito (pausa da aula, desconexão) e para de vigiar. */
  stop() {
    this.wantsStream = false;
    this.clearTimer();
    this.img.removeAttribute('src');
  }

  connect() {
    if (!this.wantsStream) return;
    this.clearTimer();
    // O parâmetro variável evita que o navegador reaproveite a conexão morta do cache.
    this.img.src = `${this.streamUrl}?t=${Date.now()}`;
  }

  handleInterruption(reason) {
    if (!this.wantsStream) return;
    // Ignora o disparo causado por limpar o src ao parar o stream.
    if (!this.img.getAttribute('src')) return;

    this.attempts += 1;
    const delay = Math.min(
      STREAM_RETRY_BASE_MS * Math.pow(2, this.attempts - 1),
      STREAM_RETRY_MAX_MS
    );

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
}
