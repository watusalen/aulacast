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
    pausas: [],
    start() { videoPlayer.chamadas.push('start'); },
    stop() { videoPlayer.chamadas.push('stop'); },
    definirPausado(p) { videoPlayer.pausas.push(p); },
    semSuporte: false,
    tentarDeNovo() { videoPlayer.chamadas.push('tentarDeNovo'); return true; }
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

test('item 7: depois do fallback, STREAM_STARTED e CONNECTED (live/paused) não ligam o H.264 de novo', () => {
  const { app, vigia, videoPlayer } = novoApp();
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');
  assert.deepStrictEqual(videoPlayer.chamadas, ['start']);
  assert.strictEqual(vigia.chamadas.includes('start'), true, 'MJPEG de pé');

  app.handleServerMessage({ type: 'STREAM_STARTED' });
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live' } });
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'paused' } });

  assert.deepStrictEqual(videoPlayer.chamadas, ['start'], 'nenhum start() novo: seria banda dobrada');
});

test('item 7: com o H.264 de pé, reconexão do WebSocket em estado live não liga o MJPEG', () => {
  const { app, vigia, videoPlayer } = novoApp();
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live' } });
  app.handleStateChange('connected', 0);
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live' } });

  assert.strictEqual(vigia.chamadas.includes('start'), false);
  assert.ok(videoPlayer.chamadas.every((c) => c === 'start'));
});

test('item 2/5: pausa e retomada chegam ao player (pausada não é queda; entrar pausado também)', () => {
  const { app, videoPlayer } = novoApp();
  app.handleServerMessage({ type: 'STREAM_PAUSED' });
  app.handleServerMessage({ type: 'STREAM_RESUMED' });
  assert.deepStrictEqual(videoPlayer.pausas, [true, false]);

  videoPlayer.pausas.length = 0;
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'paused' } });
  assert.deepStrictEqual(videoPlayer.pausas, [true]);
  assert.strictEqual(elementos.pausedOverlay.hidden, false, 'quem entra pausado vê o aviso de pausa');
  assert.strictEqual(elementos.placeholder.hidden, false, 'e o palco de aguardando, não um <video> preto');
});

// ---- Volta ao H.264 depois do fallback ----

/** Troca o relógio do retorno por um que o teste dispara na mão. */
function comRelogioFalso(app) {
  const marcados = [];
  app.retorno.setTimer = (fn, ms) => { const t = { fn, ms }; marcados.push(t); return t; };
  app.retorno.clearTimer = () => {};
  app.retorno.sorteio = () => 0;
  return marcados;
}

test('cair para o MJPEG agenda a volta ao H.264, e ao disparar o player tenta de novo', () => {
  const { app, videoPlayer } = novoApp();
  const marcados = comRelogioFalso(app);
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');

  assert.strictEqual(marcados.length, 1);
  assert.strictEqual(marcados[0].ms, 30_000);
  marcados[0].fn();
  assert.ok(videoPlayer.chamadas.includes('tentarDeNovo'));
});

test('sem suporte a MediaSource, não agenda volta nenhuma', () => {
  const { app, videoPlayer } = novoApp();
  const marcados = comRelogioFalso(app);
  videoPlayer.semSuporte = true;
  videoPlayer.opcoesRecebidas.onFallback('sem suporte a MediaSource/fetch neste navegador');
  assert.strictEqual(marcados.length, 0);
});

test('prova que deu certo (onRecuperou) desliga o MJPEG e religa o H.264 como rota normal', () => {
  const { app, vigia, videoPlayer } = novoApp();
  const marcados = comRelogioFalso(app);
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');
  assert.strictEqual(app.h264Desistiu, true);

  videoPlayer.opcoesRecebidas.onRecuperou();

  assert.strictEqual(app.h264Desistiu, false);
  assert.strictEqual(vigia.chamadas[vigia.chamadas.length - 1], 'stop', 'MJPEG desligado');
  assert.strictEqual(app.retorno.tentativas, 0, 'a espera recomeça da primeira');
  assert.strictEqual(app.retorno.timer, null, 'nada de relógio pendente depois que o H.264 voltou');
  assert.ok(marcados.length >= 1);

  // E se cair de novo mais tarde, o MJPEG é religado como na primeira vez.
  const religados = vigia.chamadas.filter((c) => c === 'start').length;
  videoPlayer.opcoesRecebidas.onFallback('caiu de novo');
  assert.strictEqual(vigia.chamadas.filter((c) => c === 'start').length, religados + 1);
});

test('prova que falha NÃO religa o MJPEG nem repete o evento de rota (ele nunca saiu do ar)', () => {
  const { app, vigia, videoPlayer } = novoApp();
  comRelogioFalso(app);
  const eventos = [];
  globalThis.AulaCastMetricas = { evento: (...a) => eventos.push(a) };
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');
  const starts = vigia.chamadas.filter((c) => c === 'start').length;

  videoPlayer.opcoesRecebidas.onFallback('prova: sem reproduzir em 15 s');
  videoPlayer.opcoesRecebidas.onFallback('prova: rede caiu');

  assert.strictEqual(vigia.chamadas.filter((c) => c === 'start').length, starts, 'MJPEG não é religado a cada prova');
  assert.strictEqual(eventos.length, 1, 'só a primeira queda vira evento de rota');
  delete globalThis.AulaCastMetricas;
});

test('transmissão pausada: a prova não roda (o servidor não manda quadros) e não gasta tentativa', () => {
  const { app, videoPlayer } = novoApp();
  const marcados = comRelogioFalso(app);
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');
  app.handleServerMessage({ type: 'STREAM_PAUSED' });

  marcados[0].fn();

  assert.strictEqual(videoPlayer.chamadas.includes('tentarDeNovo'), false);
  assert.strictEqual(app.retorno.tentativas, 0);
  assert.strictEqual(marcados.length, 2);

  app.handleServerMessage({ type: 'STREAM_RESUMED' });
  marcados[1].fn();
  assert.ok(videoPlayer.chamadas.includes('tentarDeNovo'), 'retomada: volta a tentar');
});

test('aba oculta: não faz a prova (vídeo mudo em segundo plano não toca)', () => {
  const { app, videoPlayer } = novoApp();
  const marcados = comRelogioFalso(app);
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');
  globalThis.document.visibilityState = 'hidden';
  marcados[0].fn();
  globalThis.document.visibilityState = 'visible';

  assert.strictEqual(videoPlayer.chamadas.includes('tentarDeNovo'), false);
  assert.strictEqual(app.retorno.tentativas, 0);
});

test('transmissão encerrada: o relógio dispara mas não tenta H.264 (e fica marcado para depois)', () => {
  const { app, videoPlayer } = novoApp();
  const marcados = comRelogioFalso(app);
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');
  app.handleServerMessage({ type: 'STREAM_ENDED', payload: {} });

  marcados[0].fn();

  assert.strictEqual(videoPlayer.chamadas.includes('tentarDeNovo'), false);
  assert.strictEqual(marcados.length, 2, 'marcou outra tentativa');
});

test('reconexão do WebSocket em MJPEG garante que a volta está marcada, sem ligar o H.264 direto', () => {
  const { app, videoPlayer } = novoApp();
  const marcados = comRelogioFalso(app);
  app.handleServerMessage({ type: 'STREAM_STARTED' });
  videoPlayer.opcoesRecebidas.onFallback('caiu demais');
  marcados[0].fn();
  const aposTentativa = marcados.length;

  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live' } });

  assert.strictEqual(marcados.length, aposTentativa + 1);
  assert.deepStrictEqual(videoPlayer.chamadas.filter((c) => c === 'start'), ['start'], 'nenhum start() novo');
});
