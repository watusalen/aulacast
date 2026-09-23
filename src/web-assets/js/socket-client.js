import {
  ConnectionState,
  RECONNECT_INTERVAL_MS,
  RECONNECT_FAST_ATTEMPTS,
  RECONNECT_MAX_INTERVAL_MS
} from './config.js';

/** Sem nenhuma mensagem do servidor por este tempo, a conexão é dada como morta. */
export const SERVER_SILENCE_TIMEOUT_MS = 25000;

export class SocketClient {
  constructor(onStateChange, onMessage) {
    this.ws = null;
    this.onStateChange = onStateChange;
    this.onMessage = onMessage;

    this.reconnectAttempts = 0;
    this.fastAttempts = RECONNECT_FAST_ATTEMPTS;
    this.reconnectIntervalMs = RECONNECT_INTERVAL_MS;
    this.maxIntervalMs = RECONNECT_MAX_INTERVAL_MS;
    this.reconnectTimer = null;
    this.heartbeatTimer = null;
    this.manuallyStopped = false;
    this.lastMessageAt = 0;
  }

  /**
   * Ritmo das tentativas: 2s durante o primeiro minuto e, depois, intervalos maiores
   * (até o teto) para continuar tentando indefinidamente sem martelar a rede.
   */
  nextDelay() {
    if (this.reconnectAttempts <= this.fastAttempts) {
      return this.reconnectIntervalMs;
    }
    const extra = this.reconnectAttempts - this.fastAttempts;
    return Math.min(this.reconnectIntervalMs * (1 + extra), this.maxIntervalMs);
  }

  connect() {
    this.manuallyStopped = false;
    if (this.ws) {
      this.cleanup();
    }

    const state = this.reconnectAttempts > 0 ? ConnectionState.RECONNECTING : ConnectionState.CONNECTING;
    this.onStateChange(state, this.reconnectAttempts);

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}/ws`;

    try {
      this.ws = new WebSocket(wsUrl);
      this.ws.onopen = () => this.handleOpen();
      this.ws.onmessage = (e) => this.handleMessage(e);
      this.ws.onclose = () => this.handleClose();
      this.ws.onerror = (err) => this.handleError(err);
    } catch (err) {
      console.error('Erro ao conectar WebSocket:', err);
      this.handleClose();
    }
  }

  /** Reseta as tentativas e forca uma nova conexao imediata (botao "Tentar de novo"). */
  retryNow() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.reconnectAttempts = 0;
    this.connect();
  }

  handleOpen() {
    this.reconnectAttempts = 0;
    this.lastMessageAt = Date.now();
    this.onStateChange(ConnectionState.CONNECTED, 0);
    this.startHeartbeat();
  }

  handleMessage(event) {
    this.lastMessageAt = Date.now();
    try {
      const data = JSON.parse(event.data);
      if (data.type !== 'PONG') {
        this.onMessage(data);
      }
    } catch (e) {
      console.error('Erro ao interpretar mensagem:', e);
    }
  }

  handleClose() {
    this.stopHeartbeat();

    if (this.manuallyStopped) return;

    // Nunca desiste sozinho: continua tentando, apenas espaçando as tentativas.
    this.onStateChange(ConnectionState.RECONNECTING, this.reconnectAttempts);
    this.scheduleReconnect();
  }

  handleError(error) {
    console.error('Erro no WebSocket:', error);
    if (this.ws) {
      this.ws.close();
    }
  }

  isConnected() {
    return !!this.ws && this.ws.readyState === WebSocket.OPEN;
  }

  isConnecting() {
    return !!this.ws && this.ws.readyState === WebSocket.CONNECTING;
  }

  /** Devolve se a mensagem saiu, para quem chama não fingir que foi entregue. */
  send(data) {
    if (!this.isConnected()) return false;
    this.ws.send(JSON.stringify(data));
    return true;
  }

  scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectAttempts++;

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, this.nextDelay());
  }

  startHeartbeat() {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      // O PONG é a prova de vida do servidor. Se o Mac dormiu ou o aluno trocou de
      // ponto de acesso, o `onclose` pode levar minutos: nesse meio-tempo a página dizia
      // "Conectado" com o vídeo congelado e o chat indo para lugar nenhum.
      if (Date.now() - this.lastMessageAt > SERVER_SILENCE_TIMEOUT_MS) {
        this.cleanup();
        this.handleClose();
        return;
      }
      this.send({ type: 'PING' });
    }, 10000);
  }

  stopHeartbeat() {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  cleanup() {
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onmessage = null;
      this.ws.onclose = null;
      this.ws.onerror = null;
      this.ws.close();
      this.ws = null;
    }
  }
}
