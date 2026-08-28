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
  'disconnectedState', 'pausedOverlay', 'handBanner', 'fullscreenBtn', 'sidebar',
  'menuToggleBtn', 'studentBadge', 'raiseHandBtn', 'handText', 'retryConnectionBtn',
  'chatForm', 'chatMessageInput', 'chatMessages', 'chatSendBtn',
  'entryGate', 'entryForm', 'entryName', 'entryMatricula', 'entryError', 'entrySubmit'
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
  // Sem rede nos testes: o app só precisa achar que está conectado para despachar.
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
