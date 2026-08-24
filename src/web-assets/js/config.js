export const ConnectionState = Object.freeze({
  DISCONNECTED: 'disconnected',
  CONNECTING: 'connecting',
  CONNECTED: 'connected',
  RECONNECTING: 'reconnecting'
});

/**
 * RNF-08: reconexão automática. O requisito pede tentativas a cada 2s por até 1 minuto;
 * mantemos esse ritmo no primeiro minuto (quando a maioria das oscilações se resolve) e,
 * em vez de desistir, seguimos tentando com intervalo maior — uma queda de Wi-Fi de dois
 * minutos não deve exigir que a turma inteira recarregue a página.
 */
export const RECONNECT_INTERVAL_MS = 2000;
/** Após este número de tentativas rápidas, o intervalo passa a crescer. */
export const RECONNECT_FAST_ATTEMPTS = 30;
export const RECONNECT_MAX_INTERVAL_MS = 15000;

/** Nova tentativa do stream de vídeo: começa rápido e cresce até um teto. */
export const STREAM_RETRY_BASE_MS = 1000;
export const STREAM_RETRY_MAX_MS = 10000;

