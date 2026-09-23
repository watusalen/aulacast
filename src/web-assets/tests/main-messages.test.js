import test from 'node:test';
import assert from 'node:assert';

/**
 * Exercita o despachante de mensagens do cliente real (`handleServerMessage`), que é onde
 * a aula que volta ficava sem tratamento: o servidor mandava o aviso e ninguém o escutava.
 *
 * O vigia do vídeo e o módulo que mantém a tela acesa entram como dublês: aqui interessa
 * o que o app pede a eles, e cada um tem os próprios testes.
 */
function criarElemento(tag = 'div') {
  const filhos = {};
  const el = {
    tagName: tag.toUpperCase(),
    className: '',
    textContent: '',
    title: '',
    value: '',
    hidden: false,
    disabled: false,
    filhos: [],
    listeners: {},
    classes: new Set(),
    attrs: {},
    scrollTop: 0,
    scrollHeight: 100,
    clientHeight: 0,
    classList: {
      add: (c) => el.classes.add(c),
      remove: (c) => el.classes.delete(c),
      toggle: (c) => (el.classes.has(c) ? (el.classes.delete(c), false) : (el.classes.add(c), true)),
      contains: (c) => el.classes.has(c)
    },
    filhosPorSeletor: filhos,
    querySelector: (seletor) => filhos[seletor] ?? null,
    get firstChild() { return el.filhos[0] || null; },
    appendChild(filho) { el.filhos.push(filho); },
    removeChild(filho) { el.filhos.splice(el.filhos.indexOf(filho), 1); },
    addEventListener(evt, fn) { (el.listeners[evt] ||= []).push(fn); },
    dispatch(evt, dados) { (el.listeners[evt] || []).forEach((fn) => fn(dados)); },
    setAttribute(nome, valor) { el.attrs[nome] = valor; },
    getAttribute(nome) { return el.attrs[nome] ?? null; },
    removeAttribute(nome) { delete el.attrs[nome]; },
    setSelectionRange() {},
    focus() {},
    blur() {}
  };
  return el;
}

const elementos = {};
const nomes = [
  'connectionStatus', 'videoStream', 'placeholder', 'reconnectOverlay', 'reconnectAttempt',
  'disconnectedState', 'pausedOverlay', 'fullscreenBtn', 'sidebar', 'sidebarBackdrop',
  'sidebarCloseBtn', 'panelTitle', 'app', 'studentBadge', 'retryConnectionBtn',
  'chatToggleBtn', 'filesToggleBtn', 'chatBadge', 'filesBadge', 'chatArea', 'filesArea',
  'filesList', 'filesEmpty',
  'chatForm', 'chatMessageInput', 'chatMessages', 'chatSendBtn', 'raiseHandBtn',
  'chatPinned', 'chatPinnedText', 'chatPinnedMore',
  'entryGate', 'entryForm', 'entryName', 'entryError', 'entrySubmit'
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
globalThis.window = {
  location: { protocol: 'http:', host: '127.0.0.1:8080' },
  addEventListener() {},
  removeEventListener() {}
};
// Nenhum teste abre conexão de verdade: o Node 22 já traz um WebSocket que tentaria.
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
  const telaAcesa = {
    chamadas: [],
    ativar() { telaAcesa.chamadas.push('ativar'); },
    instalarNoPrimeiroGesto() { telaAcesa.chamadas.push('instalarNoPrimeiroGesto'); }
  };
  return { vigia, telaAcesa };
}

function novoApp() {
  // Os ouvintes de clique dos apps anteriores continuam nos mesmos elementos falsos.
  for (const nome of nomes) elementos[nome].listeners = {};
  const { vigia, telaAcesa } = criarDubles();
  const app = new AulaCastApp({ criarVigia: () => vigia, telaAcesa });
  const enviadas = [];
  // Sem rede nos testes: o despachante de mensagens não depende da conexão.
  app.socket.isConnected = () => false;
  app.socket.send = (m) => { enviadas.push(m); return true; };
  return { app, vigia, telaAcesa, enviadas };
}

test('STREAM_ENDED coloca o aluno na tela de aula encerrada', () => {
  const { app, vigia } = novoApp();
  app.handleServerMessage({ type: 'STREAM_ENDED', payload: { reason: 'Monitor desconectado.' } });

  assert.strictEqual(elementos.placeholder.querySelector('.placeholder-title').textContent, 'Transmissão encerrada');
  assert.strictEqual(vigia.chamadas.at(-1), 'stop');
});

test('STREAM_STARTED devolve o vídeo a quem já estava conectado', () => {
  const { app, vigia } = novoApp();
  app.handleServerMessage({ type: 'STREAM_ENDED', payload: { reason: 'Monitor desconectado.' } });
  app.handleServerMessage({ type: 'STREAM_STARTED' });

  assert.strictEqual(vigia.chamadas.at(-1), 'start', 'o vídeo volta a ser pedido');
  assert.strictEqual(elementos.placeholder.querySelector('.placeholder-title').textContent, 'Aguardando transmissão');
});

test('CONNECTED sem payload não derruba o cliente', () => {
  const { app } = novoApp();
  assert.doesNotThrow(() => app.handleServerMessage({ type: 'CONNECTED' }));
});

test('Quem conecta com a aula pausada vê o aviso de pausa', () => {
  const { app } = novoApp();
  app.handleServerMessage({ type: 'CONNECTED', payload: { chatEnabled: true, stream: 'paused' } });
  assert.strictEqual(elementos.pausedOverlay.hidden, false);
});

test('Quem conecta depois da queda vê "Transmissão encerrada", não um quadro velho', () => {
  const { app, vigia } = novoApp();
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'ended', reason: 'Monitor desconectado.' } });

  assert.strictEqual(elementos.placeholder.querySelector('.placeholder-title').textContent, 'Transmissão encerrada');
  assert.strictEqual(vigia.chamadas.at(-1), 'stop');
});

test('Reconectar tira o aviso de pausa que ficou de antes da queda', () => {
  const { app } = novoApp();
  app.handleServerMessage({ type: 'STREAM_PAUSED' });
  app.ui.updateState('connected');
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live' } });

  assert.strictEqual(elementos.pausedOverlay.hidden, true);
});

test('Queda do WebSocket congela o vídeo em vez de apagá-lo', () => {
  const { app, vigia } = novoApp();
  app.handleStateChange('connected', 0);
  elementos.videoStream.dispatch('load');
  app.handleStateChange('reconnecting', 1);

  assert.strictEqual(vigia.chamadas.at(-1), 'congelar');
  assert.strictEqual(elementos.reconnectOverlay.hidden, false);
});

// MARK: - Levantar a mão

test('Ao reconectar, o aluno se identifica de novo e só então reenvia a mão levantada', () => {
  const { app, enviadas } = novoApp();
  app.identidade = { name: 'Ana Beatriz' };

  app.enviarIdentificacao();
  assert.ok(enviadas.some((m) => m.type === 'IDENTIFY'));
  assert.ok(!enviadas.some((m) => m.type === 'RAISE_HAND'), 'mão baixada não vai');

  elementos.raiseHandBtn.dispatch('click');
  enviadas.length = 0;
  app.handleStateChange('connected', 0);
  assert.deepStrictEqual(enviadas.map((m) => m.type).filter((t) => t !== 'PRESENCE'), ['IDENTIFY', 'RAISE_HAND'],
    'o servidor só aceita a mão de quem já se identificou');
  assert.deepStrictEqual(enviadas.at(-1).payload, { active: true });
});

test('RAISE_HAND_ACK confirma o estado do botão', () => {
  const { app } = novoApp();
  elementos.raiseHandBtn.dispatch('click');
  assert.strictEqual(elementos.raiseHandBtn.attrs['aria-pressed'], 'true');

  app.handleServerMessage({ type: 'RAISE_HAND_ACK', payload: { active: false } });
  assert.strictEqual(elementos.raiseHandBtn.attrs['aria-pressed'], 'false');
});

test('HAND_LOWERED volta o botão ao normal e deixa uma linha curta no chat', () => {
  const { app } = novoApp();
  elementos.raiseHandBtn.dispatch('click');
  const antes = elementos.chatMessages.filhos.length;

  app.handleServerMessage({ type: 'HAND_LOWERED' });
  assert.strictEqual(elementos.raiseHandBtn.attrs['aria-pressed'], 'false');
  assert.strictEqual(elementos.raiseHandBtn.attrs['aria-label'], 'Levantar a mão');
  const linha = elementos.chatMessages.filhos.at(-1);
  assert.strictEqual(linha.filhos[0].textContent, 'O professor abaixou sua mão');

  app.handleServerMessage({ type: 'HAND_LOWERED' });
  assert.strictEqual(elementos.chatMessages.filhos.length, antes + 1, 'repetido não repete a linha');
});

test('Levantar a mão funciona com o chat desligado: não é escrever', () => {
  const { app, enviadas } = novoApp();
  app.handleServerMessage({ type: 'CHAT_STATE', payload: { enabled: 'false' } });
  assert.strictEqual(elementos.chatMessageInput.disabled, true);

  elementos.raiseHandBtn.dispatch('click');
  assert.deepStrictEqual(enviadas.at(-1), { type: 'RAISE_HAND', payload: { active: true } });
});

// MARK: - Contadores

test('Arquivo novo aparece na lista e soma no contador de Arquivos', () => {
  const { app } = novoApp();
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live', files: [] } });
  app.handleServerMessage({ type: 'FILES', payload: { files: [{ id: 'f1', name: 'Lista 1.pdf', size: 2048 }] } });

  assert.strictEqual(elementos.filesList.hidden, false);
  assert.strictEqual(elementos.filesBadge.hidden, false, 'o botão de Arquivos mostra o contador');
  assert.strictEqual(elementos.filesBadge.textContent, '1');
  assert.strictEqual(elementos.chatMessages.filhos.at(-1).filhos[0].textContent, 'Novo arquivo: Lista 1.pdf',
    'e o chat ganha a linha de sistema');
});

test('Resposta do professor com o chat fechado soma no contador do Chat', () => {
  const { app } = novoApp();
  app.ui.zerarNaoLidas('chat');
  app.handleServerMessage({ type: 'CHAT_MESSAGE', payload: { sender: 'Professor', text: 'Oi', isProf: true } });
  app.handleServerMessage({ type: 'CHAT_MESSAGE', payload: { sender: 'Ana', text: 'eco da minha', isProf: false } });
  assert.strictEqual(elementos.chatBadge.textContent, '1', 'só a mensagem do professor conta');
});

// MARK: - Mensagem fixada

test('CHAT_PINNED fixa no topo do chat e, com o chat fechado, conta no botão', () => {
  const { app } = novoApp();
  app.ui.zerarNaoLidas('chat');
  app.handleServerMessage({ type: 'CHAT_PINNED', payload: { text: 'Portal: https://portal.edu.br' } });

  assert.strictEqual(elementos.chatPinned.hidden, false);
  assert.strictEqual(elementos.chatPinnedText.filhos[1].href, 'https://portal.edu.br');
  assert.strictEqual(elementos.chatBadge.textContent, '1');

  app.handleServerMessage({ type: 'CHAT_PINNED', payload: { text: null } });
  assert.strictEqual(elementos.chatPinned.hidden, true, 'text null desafixa');
  assert.strictEqual(elementos.chatBadge.textContent, '1', 'desafixar não é novidade');
});

test('A fixada que vem no CONNECTED aparece, mas não conta como novidade', () => {
  const { app } = novoApp();
  app.ui.zerarNaoLidas('chat');
  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live', pinned: 'Prova na sexta' } });

  assert.strictEqual(elementos.chatPinned.hidden, false);
  assert.strictEqual(elementos.chatPinnedText.filhos[0].textContent, 'Prova na sexta');
  assert.strictEqual(elementos.chatBadge.hidden, true);

  app.handleServerMessage({ type: 'CONNECTED', payload: { stream: 'live' } });
  assert.strictEqual(elementos.chatPinned.hidden, true, 'sem pinned, sem fixada');
});

// MARK: - Manter a tela acesa

test('Entrar pelo formulário ativa a tela acesa dentro do gesto do aluno', () => {
  const { app, telaAcesa } = novoApp();
  app.socket.retryNow = () => {};
  elementos.entryName.value = 'Ana Beatriz';
  app.entryGate.handleSubmit({ preventDefault() {} });

  assert.deepStrictEqual(telaAcesa.chamadas, ['ativar']);
});

test('Quem entra sozinho com a identidade salva ativa a tela acesa no primeiro toque', () => {
  globalThis.sessionStorage = { getItem: () => JSON.stringify({ name: 'Ana Beatriz' }), setItem() {}, removeItem() {} };
  try {
    const { telaAcesa } = novoApp();
    assert.deepStrictEqual(telaAcesa.chamadas, ['instalarNoPrimeiroGesto']);
  } finally {
    delete globalThis.sessionStorage;
  }
});
