import test from 'node:test';
import assert from 'node:assert';

/**
 * Exercita o despachante de mensagens do cliente real (`handleServerMessage`), que é onde
 * a aula que volta ficava sem tratamento: o servidor mandava o aviso e ninguém o escutava.
 */
function criarElemento() {
  const filhos = {};
  const el = {
    className: '',
    textContent: '',
    value: '',
    hidden: false,
    disabled: false,
    filhos: [],
    listeners: {},
    classes: new Set(),
    attrs: {},
    scrollTop: 0,
    scrollHeight: 100,
    selectionStart: 0,
    classList: {
      add: (c) => el.classes.add(c),
      remove: (c) => el.classes.delete(c),
      toggle: (c) => (el.classes.has(c) ? (el.classes.delete(c), false) : (el.classes.add(c), true)),
      contains: (c) => el.classes.has(c)
    },
    filhosPorSeletor: filhos,
    querySelector: (seletor) => filhos[seletor] ?? null,
    closest: () => criarElemento(),
    appendChild(filho) { el.filhos.push(filho); },
    addEventListener(evt, fn) { (el.listeners[evt] ||= []).push(fn); },
    dispatch(evt) { (el.listeners[evt] || []).forEach((fn) => fn(evt)); },
    setAttribute(nome, valor) { el.attrs[nome] = valor; },
    getAttribute(nome) { return el.attrs[nome] ?? null; },
    removeAttribute(nome) { delete el.attrs[nome]; },
    setSelectionRange() {},
    focus() {},
    blur() {},
    set src(v) { el.attrs.src = v; },
    get src() { return el.attrs.src ?? ''; }
  };
  return el;
}

const elementos = {};
const nomes = [
  'connectionStatus', 'videoStream', 'placeholder', 'reconnectOverlay', 'reconnectAttempt',
  'disconnectedState', 'pausedOverlay', 'fullscreenBtn', 'sidebar',
  'menuToggleBtn', 'studentBadge', 'retryConnectionBtn',
  'chatForm', 'chatMessageInput', 'chatMessages', 'chatSendBtn',
  'entryGate', 'entryForm', 'entryName', 'entryError', 'entrySubmit'
];
for (const nome of nomes) elementos[nome] = criarElemento();

elementos.connectionStatus.filhosPorSeletor['.status-text'] = criarElemento();
elementos.placeholder.filhosPorSeletor['.placeholder-title'] = criarElemento();
elementos.placeholder.filhosPorSeletor['.placeholder-sub'] = criarElemento();
elementos.placeholder.filhosPorSeletor['.spinner'] = criarElemento();

globalThis.document = {
  getElementById: (id) => elementos[id] ?? null,
  createElement: () => criarElemento(),
  addEventListener() {},
  visibilityState: 'visible',
  hasFocus: () => true
};
globalThis.window = {
  location: { protocol: 'http:', host: '127.0.0.1:8080' },
  addEventListener() {},
  removeEventListener() {}
};

const { AulaCastApp } = await import('../js/main.js');

function novoApp() {
  const app = new AulaCastApp();
  // Sem rede nos testes: o despachante de mensagens não depende da conexão.
  app.socket.isConnected = () => false;
  return app;
}

test('STREAM_ENDED coloca o aluno na tela de aula encerrada', () => {
  const app = novoApp();
  app.handleServerMessage({ type: 'STREAM_ENDED', payload: { reason: 'Monitor desconectado.' } });

  assert.strictEqual(
    elementos.placeholder.querySelector('.placeholder-title').textContent,
    'Transmissão encerrada'
  );
  assert.strictEqual(app.ui.streamWatchdog.wantsStream, false);
});

test('STREAM_STARTED devolve o vídeo a quem já estava conectado', () => {
  const app = novoApp();
  app.handleServerMessage({ type: 'STREAM_ENDED', payload: { reason: 'Monitor desconectado.' } });
  app.handleServerMessage({ type: 'STREAM_STARTED' });

  assert.strictEqual(elementos.placeholder.hidden, true, 'o aviso de encerrada sai da tela');
  assert.strictEqual(app.ui.streamWatchdog.wantsStream, true, 'o vídeo volta a ser pedido');

  app.ui.streamWatchdog.stop();
});

test('CONNECTED sem payload não derruba o cliente', () => {
  const app = novoApp();
  assert.doesNotThrow(() => app.handleServerMessage({ type: 'CONNECTED' }));
});

test('Quem conecta com a aula pausada vê o aviso de pausa', () => {
  const app = novoApp();
  app.handleServerMessage({ type: 'CONNECTED', payload: { chatEnabled: true, stream: 'paused' } });

  assert.strictEqual(elementos.pausedOverlay.hidden, false);
  app.ui.streamWatchdog.stop();
});

test('Quem conecta depois da queda vê "Transmissão encerrada", não um quadro velho', () => {
  const app = novoApp();
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'ended', reason: 'Monitor desconectado.' } });

  assert.strictEqual(
    elementos.placeholder.querySelector('.placeholder-title').textContent,
    'Transmissão encerrada'
  );
  assert.strictEqual(app.ui.streamWatchdog.wantsStream, false);
});

test('Reconectar tira o aviso de pausa que ficou de antes da queda', () => {
  const app = novoApp();
  app.handleServerMessage({ type: 'STREAM_PAUSED' });
  app.ui.updateState('connected');
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live' } });

  assert.strictEqual(elementos.pausedOverlay.hidden, true);
  app.ui.streamWatchdog.stop();
});

test('Ao reconectar, o aluno se identifica de novo e não manda mais mão levantada', () => {
  const app = novoApp();
  const enviadas = [];
  app.socket.send = (m) => { enviadas.push(m); return true; };
  app.identidade = { name: 'Ana Beatriz' };

  app.enviarIdentificacao();

  assert.ok(enviadas.some((m) => m.type === 'IDENTIFY'));
  assert.ok(!enviadas.some((m) => m.type === 'RAISE_HAND'));
});
