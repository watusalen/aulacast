import {
  ConnectionState,
  RECONNECT_INTERVAL_MS,
  RECONNECT_FAST_ATTEMPTS,
  RECONNECT_MAX_INTERVAL_MS
} from './config.js';

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
    this.onStateChange(ConnectionState.CONNECTED, 0);
    this.startHeartbeat();
  }

  handleMessage(event) {
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

  send(data) {
    if (this.isConnected()) {
      this.ws.send(JSON.stringify(data));
    }
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
