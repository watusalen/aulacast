import test from 'node:test';
import assert from 'node:assert';

/**
 * DOM mínimo para exercitar o UIController real fora do navegador.
 *
 * O caso que interessa aqui é o da aula que volta: quando a captura do professor cai, o
 * servidor continua no ar de propósito para avisar a turma, então o WebSocket nunca cai e
 * nada chama `updateState` de novo. Sem um caminho explícito de volta, o aluno ficava
 * olhando "Transmissão encerrada" com a aula já rolando.
 */
function criarElemento(classe = '') {
  const filhos = {};
  const el = {
    className: classe,
    textContent: '',
    hidden: false,
    listeners: {},
    classes: new Set(),
    attrs: {},
    classList: {
      add: (c) => el.classes.add(c),
      remove: (c) => el.classes.delete(c),
      toggle: (c) => (el.classes.has(c) ? (el.classes.delete(c), false) : (el.classes.add(c), true)),
      contains: (c) => el.classes.has(c)
    },
    filhosPorSeletor: filhos,
    querySelector: (seletor) => filhos[seletor] ?? null,
    closest: () => criarElemento(),
    addEventListener(evt, fn) { (el.listeners[evt] ||= []).push(fn); },
    dispatch(evt) { (el.listeners[evt] || []).forEach((fn) => fn()); },
    setAttribute(nome, valor) { el.attrs[nome] = valor; },
    getAttribute(nome) { return el.attrs[nome] ?? null; },
    removeAttribute(nome) { delete el.attrs[nome]; },
    set src(v) { el.attrs.src = v; },
    get src() { return el.attrs.src ?? ''; }
  };
  return el;
}

function montarDomFalso() {
  const status = criarElemento('badge');
  status.filhosPorSeletor['.status-text'] = criarElemento();

  const placeholder = criarElemento();
  placeholder.filhosPorSeletor['.placeholder-title'] = criarElemento();
  placeholder.filhosPorSeletor['.placeholder-sub'] = criarElemento();
  placeholder.filhosPorSeletor['.spinner'] = criarElemento();

  const elementos = {
    connectionStatus: status,
    videoStream: criarElemento(),
    placeholder,
    reconnectOverlay: criarElemento(),
    reconnectAttempt: criarElemento(),
    disconnectedState: criarElemento(),
    pausedOverlay: criarElemento(),
    handBanner: criarElemento(),
    fullscreenBtn: criarElemento(),
    sidebar: criarElemento(),
    menuToggleBtn: criarElemento(),
    studentBadge: criarElemento(),
    sidebarBackdrop: criarElemento()
  };

  globalThis.document = { getElementById: (id) => elementos[id] ?? null };
  globalThis.window = { location: { protocol: 'http:', host: '127.0.0.1:8080' } };

  return elementos;
}

const elementos = montarDomFalso();
const { UIController } = await import('../js/ui-controller.js');
const { ConnectionState } = await import('../js/config.js');

function novoController() {
  const ui = new UIController();
  ui.updateState(ConnectionState.CONNECTED);
  return ui;
}

test('Transmissão encerrada para de pedir vídeo e explica o motivo', () => {
  const ui = novoController();
  ui.showStreamEnded('Monitor desconectado.');

  assert.strictEqual(elementos.placeholder.hidden, false);
  assert.strictEqual(
    elementos.placeholder.querySelector('.placeholder-title').textContent,
    'Transmissão encerrada'
  );
  assert.strictEqual(
    elementos.placeholder.querySelector('.placeholder-sub').textContent,
    'Monitor desconectado.'
  );
  assert.strictEqual(ui.streamWatchdog.wantsStream, false);
});

test('Aula que volta tira o aluno do aviso de encerrada sem recarregar a página', () => {
  const ui = novoController();
  ui.showStreamEnded('Monitor desconectado.');

  ui.showStreaming();

  assert.strictEqual(elementos.placeholder.hidden, true, 'o aviso de encerrada sai da tela');
  assert.ok(elementos.videoStream.classList.contains('active'), 'o vídeo volta a aparecer');
  assert.strictEqual(ui.streamWatchdog.wantsStream, true, 'o vídeo volta a ser pedido');
  assert.match(elementos.videoStream.src, /\/stream\?t=\d+$/);

  ui.streamWatchdog.stop();
});

test('Aula que volta também apaga o aviso de pausa', () => {
  const ui = novoController();
  ui.showPaused();
  assert.strictEqual(elementos.pausedOverlay.hidden, false);

  ui.showStreaming();
  assert.strictEqual(elementos.pausedOverlay.hidden, true);

  ui.streamWatchdog.stop();
});

test('A conversa aberta no celular fecha ao tocar fora', () => {
  const ui = novoController();

  ui.toggleSidebar();
  assert.ok(elementos.sidebar.classList.contains('open'), 'a gaveta abre');
  assert.strictEqual(elementos.sidebarBackdrop.hidden, false, 'o fundo aparece junto');
  assert.strictEqual(elementos.menuToggleBtn.getAttribute('aria-expanded'), 'true');

  // É o gesto que todo mundo tenta primeiro; sem ele a gaveta só fechava pelo
  // mesmo botão que a abriu, que fica escondido atrás dela.
  elementos.sidebarBackdrop.dispatch('click');

  assert.ok(!elementos.sidebar.classList.contains('open'), 'a gaveta fecha');
  assert.strictEqual(elementos.sidebarBackdrop.hidden, true, 'o fundo some junto');
  assert.strictEqual(elementos.menuToggleBtn.getAttribute('aria-expanded'), 'false');

  ui.streamWatchdog.stop();
});
