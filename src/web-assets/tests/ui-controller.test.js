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
    fullscreenBtn: criarElemento(),
    sidebar: criarElemento(),
    menuToggleBtn: criarElemento(),
    studentBadge: criarElemento(),
    sidebarBackdrop: criarElemento(),
    app: criarElemento('app'),
    sidebarCloseBtn: criarElemento(),
    panelBadge: criarElemento()
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

/** Simula a largura da tela: `true` = celular/tablet estreito (gaveta), `false` = computador. */
function simularTela(estreita) {
  const midia = { matches: estreita, ouvintes: [], addEventListener(_, fn) { this.ouvintes.push(fn); } };
  globalThis.window.matchMedia = () => midia;
  return midia;
}

function limparPainel() {
  elementos.sidebar.classes.clear();
  elementos.app.classes.clear();
  elementos.menuToggleBtn.classes.clear();
  elementos.menuToggleBtn.listeners = {};
  elementos.sidebarCloseBtn.listeners = {};
  elementos.sidebarBackdrop.listeners = {};
}

test('O botão X dentro do painel fecha a gaveta', () => {
  limparPainel();
  simularTela(true);
  const ui = novoController();
  ui.toggleSidebar();
  assert.ok(elementos.sidebar.classList.contains('open'));
  elementos.sidebarCloseBtn.dispatch('click');
  assert.ok(!elementos.sidebar.classList.contains('open'), 'o X fecha');
  ui.streamWatchdog.stop();
  delete globalThis.window.matchMedia;
});

test('No computador, fechar o painel dá a largura toda ao vídeo, e o botão reabre', () => {
  limparPainel();
  const salvo = {};
  globalThis.localStorage = { getItem: (k) => salvo[k] ?? null, setItem: (k, v) => { salvo[k] = v; } };
  simularTela(false);
  const ui = novoController();

  assert.ok(!elementos.app.classList.contains('painel-fechado'), 'começa aberto');
  assert.strictEqual(elementos.menuToggleBtn.getAttribute('aria-expanded'), 'true');

  ui.toggleSidebar();
  assert.ok(elementos.app.classList.contains('painel-fechado'), 'fechar some com o painel');
  assert.strictEqual(elementos.menuToggleBtn.getAttribute('aria-expanded'), 'false');
  assert.strictEqual(salvo['aulacast.painelFechado'], '1', 'a escolha fica guardada');

  ui.toggleSidebar();
  assert.ok(!elementos.app.classList.contains('painel-fechado'), 'o botão reabre');
  ui.streamWatchdog.stop();
  delete globalThis.localStorage;
  delete globalThis.window.matchMedia;
});

test('Quem fechou o painel no computador o encontra fechado ao voltar', () => {
  limparPainel();
  globalThis.localStorage = { getItem: () => '1', setItem() {} };
  simularTela(false);
  const ui = novoController();
  assert.ok(elementos.app.classList.contains('painel-fechado'));
  ui.streamWatchdog.stop();
  delete globalThis.localStorage;
  delete globalThis.window.matchMedia;
});

test('Com o painel fechado, o contador soma as novidades e zera ao abrir', () => {
  limparPainel();
  simularTela(true);
  const ui = novoController();

  ui.marcarNovidade();
  ui.marcarNovidade(2);
  assert.strictEqual(elementos.panelBadge.hidden, false);
  assert.strictEqual(elementos.panelBadge.textContent, '3');

  ui.toggleSidebar();
  assert.strictEqual(elementos.panelBadge.hidden, true, 'abrir o painel zera o contador');

  ui.marcarNovidade();
  assert.strictEqual(elementos.panelBadge.hidden, true, 'com o painel aberto não há o que avisar');
  ui.streamWatchdog.stop();
  delete globalThis.window.matchMedia;
});

test('Girar o tablet para a largura de computador fecha a gaveta que estava aberta', () => {
  limparPainel();
  const midia = simularTela(true);
  const ui = novoController();
  ui.toggleSidebar();
  assert.ok(elementos.sidebar.classList.contains('open'));

  midia.matches = false;
  midia.ouvintes.forEach((fn) => fn());
  assert.ok(!elementos.sidebar.classList.contains('open'), 'a gaveta não fica por cima do vídeo');
  assert.strictEqual(elementos.sidebarBackdrop.hidden, true);
  ui.streamWatchdog.stop();
  delete globalThis.window.matchMedia;
});
