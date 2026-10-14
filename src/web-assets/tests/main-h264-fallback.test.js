import test from 'node:test';
import assert from 'node:assert';

/**
 * Exercita a decisão de qual vídeo usar (H.264/fMP4 vs MJPEG) em `AulaCastApp`: as duas
 * conexões não podem ficar de pé ao mesmo tempo — é exatamente o desperdício de banda que a
 * troca de codec existe para evitar (ver PLANO-COMPRESSAO-DE-VIDEO.md). Complementa
 * `main-messages.test.js` (que roda com `videoStreamMP4` ausente, e portanto sempre no modo
 * MJPEG puro) e `video-stream-player.test.js` (o player H.264 isolado, sem o `UIController`).
 */
function criarElemento(tag = 'div') {
  const filhos = {};
  const el = {
    tagName: tag.toUpperCase(),
    className: '',
    textContent: '',
    hidden: false,
    filhos: [],
    listeners: {},
    classes: new Set(),
    attrs: {},
    classList: {
      add: (c) => el.classes.add(c),
      remove: (c) => el.classes.delete(c),
      contains: (c) => el.classes.has(c)
    },
    filhosPorSeletor: filhos,
    querySelector: (seletor) => filhos[seletor] ?? null,
    appendChild(filho) { el.filhos.push(filho); },
    addEventListener(evt, fn) { (el.listeners[evt] ||= []).push(fn); },
    setAttribute(nome, valor) { el.attrs[nome] = valor; },
    getAttribute(nome) { return el.attrs[nome] ?? null; },
    removeAttribute(nome) { delete el.attrs[nome]; },
    focus() {},
    blur() {}
  };
  return el;
}

const elementos = {};
const nomes = [
  'connectionStatus', 'videoStream', 'videoStreamMP4', 'placeholder', 'reconnectOverlay',
  'reconnectAttempt', 'disconnectedState', 'pausedOverlay', 'fullscreenBtn', 'stage',
  'videoControls', 'sidebar', 'sidebarBackdrop', 'sidebarCloseBtn', 'panelTitle', 'app',
  'studentBadge', 'retryConnectionBtn', 'chatToggleBtn', 'filesToggleBtn', 'chatBadge',
  'filesBadge', 'chatArea', 'filesArea', 'filesList', 'filesEmpty', 'chatForm',
  'chatMessageInput', 'chatMessages', 'chatSendBtn', 'raiseHandBtn', 'chatVisibilityText',
  'chatPinned', 'chatPinnedText', 'chatPinnedMore', 'entryGate', 'entryForm', 'entryName',
  'entryError', 'entrySubmit'
];
for (const nome of nomes) elementos[nome] = criarElemento();
elementos.connectionStatus.filhosPorSeletor['.status-text'] = criarElemento();
for (const s of ['.placeholder-title', '.placeholder-sub', '.spinner', '.placeholder-icon']) {
  elementos.placeholder.filhosPorSeletor[s] = criarElemento();
}
elementos.chatPinned.hidden = true;

globalThis.document = {
  getElementById: (id) => elementos[id] ?? null,
  createElement: (tag) => criarElemento(tag),
  createTextNode: (texto) => ({ tagName: '#text', textContent: texto }),
  addEventListener() {},
  documentElement: {},
  visibilityState: 'visible',
  hasFocus: () => true
};
/** `MediaSource` presente e compatível: é o que faz `mediaSourceSuportado` dizer que sim. */
class MediaSourceComSuporte { static isTypeSupported() { return true; } }
globalThis.window = {
  location: { protocol: 'http:', host: '127.0.0.1:8080' },
  addEventListener() {},
  removeEventListener() {},
  MediaSource: MediaSourceComSuporte
};
globalThis.WebSocket = class {
  constructor() { this.readyState = 0; }
  close() {}
};
globalThis.WebSocket.OPEN = 1;
globalThis.WebSocket.CONNECTING = 0;

const { AulaCastApp } = await import('../js/main.js');

function criarDubles() {
  const vigia = {
    chamadas: [],
    start() { vigia.chamadas.push('start'); },
    stop() { vigia.chamadas.push('stop'); },
    congelar() { vigia.chamadas.push('congelar'); }
  };
  const videoPlayer = {
    chamadas: [],
    opcoesRecebidas: null,
    start() { videoPlayer.chamadas.push('start'); },
    stop() { videoPlayer.chamadas.push('stop'); }
  };
  return { vigia, videoPlayer };
}

function novoApp() {
  for (const nome of nomes) elementos[nome].listeners = {};
  const { vigia, videoPlayer } = criarDubles();
  const app = new AulaCastApp({
    criarVigia: () => vigia,
    criarVideoPlayer: (el, opcoes) => {
      videoPlayer.opcoesRecebidas = opcoes;
      return videoPlayer;
    }
  });
  app.socket.isConnected = () => false;
  app.socket.send = () => true;
  return { app, vigia, videoPlayer };
}

test('com suporte a H.264, STREAM_STARTED liga o player novo e NÃO liga o MJPEG', () => {
  const { app, vigia, videoPlayer } = novoApp();
  app.handleServerMessage({ type: 'STREAM_STARTED' });

  assert.deepStrictEqual(videoPlayer.chamadas, ['start']);
  assert.strictEqual(vigia.chamadas.includes('start'), false, 'as duas conexões não podem ficar de pé ao mesmo tempo');
});

test('o player H.264 desistindo (onFallback) liga o MJPEG que estava suprimido', () => {
  const { app, vigia, videoPlayer } = novoApp();
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  assert.strictEqual(vigia.chamadas.includes('start'), false);

  videoPlayer.opcoesRecebidas.onFallback('conexão de /stream.mp4 caiu demais seguidas');

  assert.strictEqual(vigia.chamadas.includes('start'), true, 'o fallback liga o MJPEG na hora');
});

test('quadro do H.264 chegando tira o palco de "aguardando", igual ao MJPEG', () => {
  const { app, videoPlayer } = novoApp();
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  assert.strictEqual(elementos.placeholder.hidden, false, 'aguardando até o primeiro quadro');

  videoPlayer.opcoesRecebidas.onEstado('ao-vivo');

  assert.strictEqual(elementos.placeholder.hidden, true);
});

test('STREAM_ENDED encerra o player H.264 (não só o MJPEG)', () => {
  const { app, videoPlayer } = novoApp();
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  app.handleServerMessage({ type: 'STREAM_ENDED', payload: { reason: 'Monitor desconectado.' } });

  assert.deepStrictEqual(videoPlayer.chamadas, ['start', 'stop']);
});
