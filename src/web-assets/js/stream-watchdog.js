import { STREAM_RETRY_BASE_MS, STREAM_RETRY_MAX_MS } from './config.js';

/**
 * Vigia o stream MJPEG do <img>, que é uma conexão HTTP separada do WebSocket.
 *
 * Sem isto, uma queda só do vídeo (oscilação de Wi-Fi, servidor reiniciado) deixa a
 * imagem congelada para sempre enquanto o selo de status continua dizendo "Conectado",
 * porque nada reatribui o `src`.
 *
 * Em um multipart/x-mixed-replace, o navegador dispara:
 *   - `error` quando a conexão falha;
 *   - `load`  quando a resposta multipart TERMINA (ou seja, o stream acabou).
 * Os dois significam "não está mais chegando vídeo" e disparam nova tentativa.
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
    this.img.addEventListener('load', () => this.handleInterruption('load'));
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
