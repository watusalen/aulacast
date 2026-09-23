import test from 'node:test';
import assert from 'node:assert';

/**
 * DOM mínimo para exercitar o UIController real fora do navegador.
 *
 * Cada teste monta um DOM novo (o controlador lê os elementos ao nascer), e o vigia do
 * vídeo é um dublê: o que interessa aqui é o que a tela pede a ele (começar, parar,
 * congelar), não como ele fala com o servidor — isso é testado em stream-watchdog.test.js.
 */
function criarElemento(classe = '') {
  const filhos = {};
  const el = {
    className: classe,
    textContent: '',
    title: '',
    hidden: false,
    focado: false,
    listeners: {},
    classes: new Set(),
    attrs: {},
    classList: {
      add: (c) => el.classes.add(c),
      remove: (c) => el.classes.delete(c),
      toggle: (c, forcar) => {
        const ligar = forcar === undefined ? !el.classes.has(c) : forcar;
        if (ligar) el.classes.add(c); else el.classes.delete(c);
        return ligar;
      },
      contains: (c) => el.classes.has(c)
    },
    filhosPorSeletor: filhos,
    querySelector: (seletor) => filhos[seletor] ?? null,
    addEventListener(evt, fn) { (el.listeners[evt] ||= []).push(fn); },
    dispatch(evt, dados) { (el.listeners[evt] || []).forEach((fn) => fn(dados)); },
    setAttribute(nome, valor) { el.attrs[nome] = valor; },
    getAttribute(nome) { return el.attrs[nome] ?? null; },
    removeAttribute(nome) { delete el.attrs[nome]; },
    focus() { el.focado = true; }
  };
  return el;
}

function criarVigia() {
  const vigia = {
    chamadas: [],
    opcoes: null,
    start() { vigia.chamadas.push('start'); },
    stop() { vigia.chamadas.push('stop'); },
    congelar() { vigia.chamadas.push('congelar'); }
  };
  return vigia;
}

/**
 * @param {{ estreita?: boolean, armazenado?: object, telaCheia?: boolean, modoApp?: boolean }} opcoes
 */
function montar({ estreita = false, armazenado = {}, telaCheia = true, modoApp = false } = {}) {
  const status = criarElemento('chip-estado');
  status.filhosPorSeletor['.status-text'] = criarElemento();

  const placeholder = criarElemento();
  for (const s of ['.placeholder-title', '.placeholder-sub', '.spinner', '.placeholder-icon']) {
    placeholder.filhosPorSeletor[s] = criarElemento();
  }

  const el = {
    connectionStatus: status,
    videoStream: criarElemento(),
    placeholder,
    reconnectOverlay: criarElemento(),
    reconnectAttempt: criarElemento(),
    disconnectedState: criarElemento(),
    pausedOverlay: criarElemento(),
    fullscreenBtn: criarElemento(),
    sidebar: criarElemento(),
    sidebarBackdrop: criarElemento(),
    sidebarCloseBtn: criarElemento(),
    panelTitle: criarElemento(),
    app: criarElemento('app'),
    chatToggleBtn: criarElemento(),
    filesToggleBtn: criarElemento(),
    chatBadge: criarElemento(),
    filesBadge: criarElemento(),
    chatArea: criarElemento(),
    filesArea: criarElemento(),
    studentBadge: criarElemento()
  };
  el.reconnectOverlay.hidden = true;
  el.disconnectedState.hidden = true;
  el.pausedOverlay.hidden = true;
  el.filesArea.hidden = true;

  const telaCheiaPedida = [];
  const documentElement = telaCheia ? { requestFullscreen() { telaCheiaPedida.push('entrar'); } } : {};
  const ouvintesDoDocumento = {};
  globalThis.document = {
    getElementById: (id) => el[id] ?? null,
    addEventListener(evt, fn) { (ouvintesDoDocumento[evt] ||= []).push(fn); },
    documentElement,
    fullscreenElement: null,
    activeElement: null,
    exitFullscreen() { telaCheiaPedida.push('sair'); }
  };

  const midia = {
    matches: estreita,
    ouvintes: [],
    addEventListener(_, fn) { this.ouvintes.push(fn); }
  };
  globalThis.window = {
    location: { protocol: 'http:', host: '127.0.0.1:8080' },
    matchMedia: (consulta) => (consulta.includes('display-mode') ? { matches: modoApp } : midia)
  };

  const salvo = { ...armazenado };
  globalThis.localStorage = { getItem: (k) => salvo[k] ?? null, setItem: (k, v) => { salvo[k] = v; } };

  const vigia = criarVigia();
  const tecla = (dados) => (ouvintesDoDocumento.keydown || []).forEach((fn) => fn({ preventDefault() {}, ...dados }));
  return { el, vigia, midia, salvo, telaCheiaPedida, tecla, criarVigia: (_, opcoes) => { vigia.opcoes = opcoes; return vigia; } };
}

const { UIController, ehCampoDeTexto } = await import('../js/ui-controller.js');
const { ConnectionState } = await import('../js/config.js');

function novoController(opcoes) {
  const dom = montar(opcoes);
  const ui = new UIController({ criarVigia: dom.criarVigia });
  return { ui, ...dom };
}

/** Aula no ar com imagem na tela: conectou e chegou o primeiro quadro. */
function aoVivoComQuadro(opcoes) {
  const ctx = novoController(opcoes);
  ctx.ui.updateState(ConnectionState.CONNECTED);
  ctx.el.videoStream.dispatch('load');
  return ctx;
}

// MARK: - Vídeo e estados do palco

test('Transmissão encerrada para de pedir vídeo e explica o motivo', () => {
  const { ui, el, vigia } = aoVivoComQuadro();
  ui.showStreamEnded('Monitor desconectado.');

  assert.strictEqual(el.placeholder.hidden, false);
  assert.strictEqual(el.placeholder.querySelector('.placeholder-title').textContent, 'Transmissão encerrada');
  assert.strictEqual(el.placeholder.querySelector('.placeholder-sub').textContent, 'Monitor desconectado.');
  assert.strictEqual(vigia.chamadas.at(-1), 'stop');
  assert.strictEqual(el.placeholder.querySelector('.spinner').getAttribute('hidden'), '',
    'sem indicador de progresso: não vai voltar sozinha (atributo, porque é um <svg>)');
  assert.match(el.connectionStatus.className, /encerrada/);
});

test('Aula que volta tira o aluno do aviso de encerrada sem recarregar a página', () => {
  const { ui, el, vigia } = aoVivoComQuadro();
  ui.showStreamEnded('Monitor desconectado.');

  ui.showStreaming();
  assert.strictEqual(vigia.chamadas.at(-1), 'start', 'o vídeo volta a ser pedido');
  assert.ok(el.videoStream.classList.contains('active'));
  assert.strictEqual(el.placeholder.querySelector('.placeholder-title').textContent, 'Aguardando transmissão',
    'até o primeiro quadro, o palco diz que está aguardando');
  assert.strictEqual(el.placeholder.querySelector('.spinner').getAttribute('hidden'), null, 'com o indicador girando');

  el.videoStream.dispatch('load');
  assert.strictEqual(el.placeholder.hidden, true, 'com imagem, o aviso sai');
  assert.match(el.connectionStatus.className, /ao-vivo/);
});

test('Aula que volta também apaga o aviso de pausa', () => {
  const { ui, el } = aoVivoComQuadro();
  ui.showPaused();
  assert.strictEqual(el.pausedOverlay.hidden, false);
  assert.match(el.connectionStatus.className, /pausada/);

  ui.showStreaming();
  assert.strictEqual(el.pausedOverlay.hidden, true);
});

test('Reconectando: o último quadro fica na tela, com só um aviso pequeno por cima', () => {
  const { ui, el, vigia } = aoVivoComQuadro();

  ui.updateState(ConnectionState.RECONNECTING, 3);

  assert.strictEqual(vigia.chamadas.at(-1), 'congelar', 'congela, não esconde a imagem');
  assert.ok(!vigia.chamadas.includes('stop'), 'nunca limpa a imagem numa oscilação');
  assert.ok(el.videoStream.classList.contains('active'), 'a imagem continua no palco');
  assert.strictEqual(el.placeholder.hidden, true, 'sem tela vazia');
  assert.strictEqual(el.reconnectOverlay.hidden, false);
  assert.strictEqual(el.reconnectAttempt.textContent, 'tentativa 3');
  assert.match(el.connectionStatus.className, /reconectando/);
  assert.strictEqual(el.connectionStatus.querySelector('.status-text').textContent, 'Reconectando…');

  ui.updateState(ConnectionState.CONNECTED);
  assert.strictEqual(el.reconnectOverlay.hidden, true);
  assert.strictEqual(vigia.chamadas.at(-1), 'start', 'reconectou: o vídeo volta');
  assert.strictEqual(el.placeholder.hidden, true, 'o quadro congelado segura até o novo chegar');
});

test('Sem conexão: cartão com "Tentar de novo" por cima do quadro parado', () => {
  const { ui, el, vigia } = aoVivoComQuadro();
  ui.updateState(ConnectionState.DISCONNECTED);

  assert.strictEqual(el.disconnectedState.hidden, false);
  assert.strictEqual(vigia.chamadas.at(-1), 'congelar');
  assert.strictEqual(el.placeholder.hidden, true);
  assert.match(el.connectionStatus.className, /sem-conexao/);
});

test('Primeira conexão, sem quadro ainda: o palco diz que está aguardando, sem aviso de queda', () => {
  const { ui, el } = novoController();
  ui.updateState(ConnectionState.CONNECTING);

  assert.strictEqual(el.reconnectOverlay.hidden, true);
  assert.strictEqual(el.placeholder.hidden, false);
  assert.match(el.connectionStatus.className, /conectando/);
});

test('Queda só do vídeo com o WebSocket de pé mostra o aviso até o quadro voltar', () => {
  const { ui, el, vigia } = aoVivoComQuadro();

  vigia.opcoes.onEstado('reconectando');
  assert.strictEqual(el.reconnectOverlay.hidden, false);

  vigia.opcoes.onEstado('ao-vivo');
  assert.strictEqual(el.reconnectOverlay.hidden, true);

  ui.showPaused();
  vigia.opcoes.onEstado('reconectando');
  assert.strictEqual(el.reconnectOverlay.hidden, true, 'pausada, a falta de quadros é esperada');
});

// MARK: - Painel (Chat OU Arquivos)

test('No computador, o botão do Chat abre o chat e, clicado de novo, fecha o painel', () => {
  const { el, salvo } = novoController({ armazenado: { 'aulacast.painelFechado': '1' } });
  assert.ok(el.app.classList.contains('painel-fechado'), 'quem fechou encontra fechado');

  el.chatToggleBtn.dispatch('click');
  assert.ok(!el.app.classList.contains('painel-fechado'));
  assert.strictEqual(el.chatArea.hidden, false);
  assert.strictEqual(el.filesArea.hidden, true, 'uma área por vez');
  assert.strictEqual(el.panelTitle.textContent, 'Chat');
  assert.ok(el.chatToggleBtn.classList.contains('selecionado'), 'o botão do painel aberto fica preenchido');
  assert.strictEqual(el.chatToggleBtn.getAttribute('aria-expanded'), 'true');
  assert.strictEqual(salvo['aulacast.painelFechado'], '0');

  el.chatToggleBtn.dispatch('click');
  assert.ok(el.app.classList.contains('painel-fechado'), 'clicar no botão do painel aberto fecha');
  assert.ok(!el.chatToggleBtn.classList.contains('selecionado'));
  assert.strictEqual(salvo['aulacast.painelFechado'], '1');
});

test('Com o chat aberto, o botão de Arquivos troca a área sem fechar o painel', () => {
  const { el, salvo } = novoController();
  el.filesToggleBtn.dispatch('click');

  assert.ok(!el.app.classList.contains('painel-fechado'));
  assert.strictEqual(el.chatArea.hidden, true);
  assert.strictEqual(el.filesArea.hidden, false);
  assert.strictEqual(el.panelTitle.textContent, 'Arquivos');
  assert.ok(el.filesToggleBtn.classList.contains('selecionado'));
  assert.ok(!el.chatToggleBtn.classList.contains('selecionado'));
  assert.strictEqual(salvo['aulacast.areaDoPainel'], 'arquivos', 'a escolha fica guardada');
});

test('A área escolhida volta na próxima vez', () => {
  const { el } = novoController({ armazenado: { 'aulacast.areaDoPainel': 'arquivos' } });
  assert.strictEqual(el.filesArea.hidden, false);
  assert.strictEqual(el.chatArea.hidden, true);
});

test('Sem armazenamento (modo privado), o painel funciona e só não lembra', () => {
  const dom = montar();
  globalThis.localStorage = { getItem() { throw new Error('bloqueado'); }, setItem() { throw new Error('bloqueado'); } };
  const ui = new UIController({ criarVigia: dom.criarVigia });
  assert.doesNotThrow(() => ui.alternarPainel('arquivos'));
  assert.strictEqual(dom.el.filesArea.hidden, false);
});

test('No celular o painel é folha: começa fechada, e tocar fora, o X ou Esc fecham', () => {
  const { el, tecla } = novoController({ estreita: true });
  assert.ok(!el.sidebar.classList.contains('open'), 'a imagem aparece primeiro');

  el.chatToggleBtn.dispatch('click');
  assert.ok(el.sidebar.classList.contains('open'));
  assert.strictEqual(el.sidebarBackdrop.hidden, false, 'o véu aparece junto');
  assert.ok(el.sidebarCloseBtn.focado, 'o foco entra na folha');

  el.sidebarBackdrop.dispatch('click');
  assert.ok(!el.sidebar.classList.contains('open'), 'tocar fora fecha');
  assert.strictEqual(el.sidebarBackdrop.hidden, true);
  assert.ok(el.chatToggleBtn.focado, 'o foco volta ao botão que abriu');

  el.filesToggleBtn.dispatch('click');
  el.sidebarCloseBtn.dispatch('click');
  assert.ok(!el.sidebar.classList.contains('open'), 'o X fecha');

  el.filesToggleBtn.dispatch('click');
  tecla({ key: 'Escape' });
  assert.ok(!el.sidebar.classList.contains('open'), 'Esc fecha');
});

test('Girar o tablet para a largura de computador fecha a folha que estava aberta', () => {
  const { el, midia } = novoController({ estreita: true });
  el.chatToggleBtn.dispatch('click');
  assert.ok(el.sidebar.classList.contains('open'));

  midia.matches = false;
  midia.ouvintes.forEach((fn) => fn());
  assert.ok(!el.sidebar.classList.contains('open'), 'a folha não fica por cima do vídeo');
  assert.strictEqual(el.sidebarBackdrop.hidden, true);
});

// MARK: - Contadores

test('Cada botão conta o que chegou com a sua área fechada, e zera ao abri-la', () => {
  const { ui, el } = novoController({ armazenado: { 'aulacast.painelFechado': '1' } });

  ui.marcarNovidade('chat');
  ui.marcarNovidade('chat');
  ui.marcarNovidade('arquivos', 3);
  assert.strictEqual(el.chatBadge.hidden, false);
  assert.strictEqual(el.chatBadge.textContent, '2');
  assert.strictEqual(el.filesBadge.textContent, '3');
  assert.strictEqual(el.chatToggleBtn.getAttribute('aria-label'), 'Chat, 2 novidades');

  el.filesToggleBtn.dispatch('click');
  assert.strictEqual(el.filesBadge.hidden, true, 'abrir Arquivos zera o dele');
  assert.strictEqual(el.chatBadge.textContent, '2', 'e não o do chat');

  ui.marcarNovidade('chat');
  assert.strictEqual(el.chatBadge.textContent, '3', 'com Arquivos aberto, o chat continua contando');

  el.chatToggleBtn.dispatch('click');
  assert.strictEqual(el.chatBadge.hidden, true);
  ui.marcarNovidade('chat');
  assert.strictEqual(el.chatBadge.hidden, true, 'com o chat à vista não há o que avisar');
});

test('Contador passa de 99 como "99+"', () => {
  const { ui, el } = novoController({ armazenado: { 'aulacast.painelFechado': '1' } });
  ui.marcarNovidade('chat', 120);
  assert.strictEqual(el.chatBadge.textContent, '99+');
});

test('O chat que aparece é avisado, para rolar até a mensagem mais recente', () => {
  const { ui, el } = novoController({ armazenado: { 'aulacast.painelFechado': '1' } });
  const mostradas = [];
  ui.aoMostrarArea = (area) => mostradas.push(area);

  el.chatToggleBtn.dispatch('click');
  el.filesToggleBtn.dispatch('click');
  ui.aplicarLayoutDoPainel();
  assert.deepStrictEqual(mostradas, ['chat', 'arquivos'], 'uma vez a cada troca, não a cada ajuste');
});

// MARK: - Tela cheia e tecla F

test('A tecla F entra e sai da tela cheia', () => {
  const { tecla, telaCheiaPedida } = novoController();
  tecla({ key: 'f', target: { tagName: 'BODY' } });
  assert.deepStrictEqual(telaCheiaPedida, ['entrar']);

  globalThis.document.fullscreenElement = {};
  tecla({ key: 'F', target: { tagName: 'BODY' } });
  assert.deepStrictEqual(telaCheiaPedida, ['entrar', 'sair']);
});

test('A tecla F é a letra F quando o aluno está escrevendo', () => {
  const { tecla, telaCheiaPedida } = novoController();
  tecla({ key: 'f', target: { tagName: 'INPUT', type: 'text' } });
  tecla({ key: 'f', target: { tagName: 'TEXTAREA' } });
  tecla({ key: 'f', target: { tagName: 'DIV', isContentEditable: true } });
  assert.deepStrictEqual(telaCheiaPedida, []);
});

test('Com Ctrl, Cmd ou Alt a tecla F é de outro atalho (Cmd+F é buscar)', () => {
  const { tecla, telaCheiaPedida } = novoController();
  tecla({ key: 'f', metaKey: true, target: { tagName: 'BODY' } });
  tecla({ key: 'f', ctrlKey: true, target: { tagName: 'BODY' } });
  tecla({ key: 'f', altKey: true, target: { tagName: 'BODY' } });
  assert.deepStrictEqual(telaCheiaPedida, []);
});

test('ehCampoDeTexto separa campos de texto de botões e caixas de marcar', () => {
  assert.strictEqual(ehCampoDeTexto({ tagName: 'INPUT', type: 'search' }), true);
  assert.strictEqual(ehCampoDeTexto({ tagName: 'INPUT', type: 'checkbox' }), false);
  assert.strictEqual(ehCampoDeTexto({ tagName: 'BUTTON' }), false);
  assert.strictEqual(ehCampoDeTexto(null), false);
});

test('Sem a API de tela cheia (iPhone), o botão some e a tecla F não faz nada', () => {
  const { el, tecla, telaCheiaPedida } = novoController({ telaCheia: false });
  assert.strictEqual(el.fullscreenBtn.hidden, true);
  assert.doesNotThrow(() => tecla({ key: 'f', target: { tagName: 'BODY' } }));
  assert.deepStrictEqual(telaCheiaPedida, []);
});

test('Aberta pela Tela de Início em tela cheia, o botão de tela cheia some', () => {
  const { el } = novoController({ modoApp: true });
  assert.strictEqual(el.fullscreenBtn.hidden, true);
});

test('O botão de tela cheia diz se entra ou sai', () => {
  const { ui, el } = novoController();
  assert.strictEqual(el.fullscreenBtn.getAttribute('aria-pressed'), 'false');
  globalThis.document.fullscreenElement = {};
  ui.atualizarBotaoDeTelaCheia();
  assert.strictEqual(el.fullscreenBtn.getAttribute('aria-pressed'), 'true');
  assert.strictEqual(el.fullscreenBtn.getAttribute('aria-label'), 'Sair da tela cheia (F)');
});
