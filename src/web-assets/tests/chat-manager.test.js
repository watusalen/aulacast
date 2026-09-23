import test from 'node:test';
import assert from 'node:assert';

/**
 * DOM mínimo para exercitar o ChatManager real fora do navegador.
 * Antes, este arquivo declarava uma função de formatação dentro do próprio teste e
 * verificava um formato que o aplicativo nunca produziu — não cobria nada.
 */
function criarElemento(tag = 'div') {
  const el = {
    tagName: tag.toUpperCase(),
    className: '',
    textContent: '',
    value: '',
    filhos: [],
    scrollTop: 0,
    scrollHeight: 100,
    clientHeight: 0,
    hidden: false,
    disabled: false,
    attrs: {},
    href: '',
    listeners: {},
    classes: new Set(),
    classList: {
      add: (c) => el.classes.add(c),
      remove: (c) => el.classes.delete(c),
      contains: (c) => el.classes.has(c)
    },
    get firstChild() { return el.filhos[0] || null; },
    setAttribute(nome, valor) { el.attrs[nome] = valor; },
    appendChild(filho) { el.filhos.push(filho); },
    removeChild(filho) { el.filhos.splice(el.filhos.indexOf(filho), 1); },
    addEventListener(evt, fn) { (el.listeners[evt] ||= []).push(fn); },
    dispatch(evt) { (el.listeners[evt] || []).forEach((fn) => fn()); },
    blur() {}
  };
  return el;
}

const elementos = {
  chatForm: criarElemento('form'),
  chatMessageInput: criarElemento('input'),
  chatMessages: criarElemento(),
  chatSendBtn: criarElemento('button'),
  chatPinned: criarElemento(),
  chatPinnedText: criarElemento('p'),
  chatPinnedMore: criarElemento('button')
};
elementos.chatPinned.hidden = true;

globalThis.document = {
  getElementById: (id) => elementos[id] ?? null,
  createElement: (tag) => criarElemento(tag),
  createTextNode: (texto) => ({ tagName: '#text', textContent: texto })
};

const { ChatManager } = await import('../js/chat-manager.js');

function ultima() {
  return elementos.chatMessages.filhos[elementos.chatMessages.filhos.length - 1];
}

/** Nome e hora da última mensagem ("Professor", "10:42"). */
function cabecaDaUltima() {
  const [autor, hora] = ultima().filhos[0].filhos;
  return { autor: autor.textContent, hora: hora.textContent };
}

/** O elemento com o texto da última mensagem. */
function textoDaUltima() {
  return ultima().filhos[1];
}

test('Mensagem do professor mostra o remetente do servidor sem "Prof. Professor"', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  // É isto que o servidor manda de verdade (ChatManagerService).
  chat.appendMessage('Professor', 'Aumentei a fonte do terminal.', true);

  const { autor, hora } = cabecaDaUltima();
  assert.strictEqual(autor, 'Professor');
  assert.match(hora, /^\d{2}:\d{2}$/);
  assert.match(ultima().className, /msg-prof/);
});

test('Mensagem de aluno não recebe prefixo de professor', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  chat.appendMessage('Carlos Eduardo', 'Dá pra aumentar a fonte?', false);

  assert.strictEqual(cabecaDaUltima().autor, 'Carlos Eduardo');
  assert.ok(!ultima().className.includes('msg-prof'));
});

test('A própria mensagem do aluno aparece como "Você"', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  chat.appendMessage('Ana Beatriz', 'Deu certo aqui!', false);

  assert.strictEqual(cabecaDaUltima().autor, 'Você');
  assert.match(ultima().className, /msg-own/);
});

test('Mensagem do professor nunca é marcada como do aluno', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  // Mesmo que o nome coincida com o do aluno, ser do professor tem precedência.
  chat.appendMessage('Ana Beatriz', 'Resposta do professor.', true);

  assert.ok(!ultima().className.includes('msg-own'));
  assert.strictEqual(cabecaDaUltima().autor, 'Ana Beatriz');
});

test('isOwnMessage segue o mesmo critério do "Você" em appendMessage', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');

  assert.strictEqual(chat.isOwnMessage('Ana Beatriz', false), true);
  assert.strictEqual(chat.isOwnMessage('Carlos Eduardo', false), false, 'mensagem de colega não é própria');
  // O nome coincidir não basta: sendo do professor, precedência é dele.
  assert.strictEqual(chat.isOwnMessage('Ana Beatriz', true), false);
});

test('O texto da mensagem é preservado', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  const texto = 'Qual a diferença entre let e var?';
  chat.appendMessage('Carlos Eduardo', texto, false);

  assert.strictEqual(textoDaUltima().textContent, texto);
});

test('Links do professor viram clicáveis, abrindo em outra aba', () => {
  const chat = new ChatManager(() => {}, () => 'Ana');
  chat.appendMessage('Professor', 'Material em https://portal.edu.br/aula3. Boa leitura!', true);

  const [antes, link, depois] = textoDaUltima().filhos;
  assert.strictEqual(antes.textContent, 'Material em ');
  assert.strictEqual(link.tagName, 'A');
  assert.strictEqual(link.href, 'https://portal.edu.br/aula3');
  assert.strictEqual(link.textContent, 'https://portal.edu.br/aula3', 'sem o ponto final da frase');
  assert.strictEqual(link.target, '_blank');
  assert.strictEqual(link.rel, 'noopener noreferrer');
  assert.strictEqual(depois.textContent, '. Boa leitura!');
});

test('Nas mensagens do próprio aluno os links ficam como texto', () => {
  const chat = new ChatManager(() => {}, () => 'Ana');
  chat.appendMessage('Ana', 'olha https://x.com', false);

  assert.strictEqual(textoDaUltima().filhos.length, 0, 'nenhum <a> criado');
  assert.strictEqual(textoDaUltima().textContent, 'olha https://x.com');
});

test('Enviar mensagem manda só o texto: o remetente é o nome que o servidor validou', () => {
  const enviadas = [];
  const chat = new ChatManager((m) => { enviadas.push(m); return true; }, () => 'Ana Beatriz Sousa');

  elementos.chatMessageInput.value = 'Professor, não estou enxergando.';
  chat.handleSubmit({ preventDefault() {} });

  assert.strictEqual(enviadas.length, 1);
  assert.strictEqual(enviadas[0].type, 'CHAT_SEND');
  assert.strictEqual(enviadas[0].payload.sender, undefined);
  assert.strictEqual(enviadas[0].payload.text, 'Professor, não estou enxergando.');
  assert.strictEqual(elementos.chatMessageInput.value, '', 'campo é limpo após enviar');
});

test('Sem conexão a mensagem fica no campo e o aluno é avisado', () => {
  const chat = new ChatManager(() => false, () => 'Ana Beatriz Sousa');
  const antes = elementos.chatMessages.filhos.length;

  elementos.chatMessageInput.value = 'Pergunta importante';
  chat.handleSubmit({ preventDefault() {} });

  assert.strictEqual(elementos.chatMessageInput.value, 'Pergunta importante', 'o texto não some');
  assert.strictEqual(elementos.chatMessages.filhos.length, antes + 1, 'aparece um aviso');
  assert.strictEqual(ultima().className, 'chat-aviso');
});

test('Mensagem vazia ou só com espaços não é enviada', () => {
  const enviadas = [];
  const chat = new ChatManager((m) => enviadas.push(m), () => 'Ana Beatriz Sousa');

  elementos.chatMessageInput.value = '   ';
  chat.handleSubmit({ preventDefault() {} });

  assert.strictEqual(enviadas.length, 0);
});

/**
 * O bloqueio do chat só existia no servidor: a mensagem era descartada em silêncio e o
 * aluno via o texto sumir sem explicação, como se o botão do professor não funcionasse.
 */
test('Desligar o chat inativa o campo e o botão', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  chat.setEnabled(false);

  assert.strictEqual(elementos.chatMessageInput.disabled, true, 'campo fica inativo');
  assert.strictEqual(elementos.chatSendBtn.disabled, true, 'botão fica inativo');
});

test('Religar o chat reativa o campo e o botão', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');

  // Confere o estado intermediário: sem isto o teste passaria mesmo se `setEnabled`
  // não fizesse nada, já que o campo nasce ativo e continuaria ativo no fim.
  chat.setEnabled(false);
  assert.strictEqual(elementos.chatMessageInput.disabled, true, 'bloqueou de fato antes de religar');

  chat.setEnabled(true);
  assert.strictEqual(elementos.chatMessageInput.disabled, false);
  assert.strictEqual(elementos.chatSendBtn.disabled, false);
});

// O campo inativo barra o aluno pela interface, mas o submit ainda pode partir de um
// script: o bloqueio no cliente não pode depender só do atributo `disabled`.
test('Com o chat desligado, nada é enviado ao servidor', () => {
  const enviadas = [];
  const chat = new ChatManager((m) => enviadas.push(m), () => 'Ana Beatriz');

  chat.setEnabled(false);
  elementos.chatMessageInput.value = 'insistindo mesmo assim';
  chat.handleSubmit({ preventDefault() {} });

  assert.strictEqual(enviadas.length, 0);
});

test('O texto pendente é descartado ao bloquear', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');

  elementos.chatMessageInput.value = 'estava digitando quando bloqueou';
  chat.setEnabled(false);

  // Um campo inativo com texto parado dentro parece travado, não desligado.
  assert.strictEqual(elementos.chatMessageInput.value, '');
});

test('Religar reativa antes de qualquer envio, sem sobra do bloqueio', () => {
  const enviadas = [];
  const chat = new ChatManager((m) => enviadas.push(m), () => 'Ana Beatriz');

  chat.setEnabled(false);
  chat.setEnabled(true);
  elementos.chatMessageInput.value = 'voltei a poder falar';
  chat.handleSubmit({ preventDefault() {} });

  assert.strictEqual(enviadas.length, 1);
  assert.strictEqual(enviadas[0].payload.text, 'voltei a poder falar');
});

test('Chat começa liberado até o servidor dizer o contrário', () => {
  const enviadas = [];
  const chat = new ChatManager((m) => enviadas.push(m), () => 'Ana Beatriz');

  elementos.chatMessageInput.value = 'antes de qualquer CHAT_STATE';
  chat.handleSubmit({ preventDefault() {} });

  assert.strictEqual(enviadas.length, 1);
});

test('Arquivo novo vira uma linha de sistema, sem nada para clicar', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  const antes = elementos.chatMessages.filhos.length;
  chat.mostrarArquivosNovos([{ id: 'x1', name: 'Lista 3.pdf', size: 184000 }]);

  const linha = elementos.chatMessages.filhos[antes];
  assert.strictEqual(linha.className, 'chat-event');
  assert.strictEqual(linha.attrs.role, 'status');
  assert.strictEqual(linha.filhos[0].textContent, 'Novo arquivo: Lista 3.pdf');
  assert.strictEqual(linha.filhos[0].attrs.title, 'Lista 3.pdf', 'o nome inteiro fica na dica');
  assert.match(linha.filhos[1].textContent, /^\d{2}:\d{2}$/);
  const temLink = (el) => el.href || (el.filhos || []).some(temLink);
  assert.ok(!temLink(linha), 'o download fica só na lista de Arquivos');
});

test('Vários arquivos: a linha diz quantos, sem listar nomes', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  chat.mostrarArquivosNovos([
    { id: 'a', name: 'a.zip', size: 10 },
    { id: 'b', name: '<b>c</b>.txt', size: 5 },
    { id: 'c', name: 'c.pdf', size: 5 }
  ]);
  assert.strictEqual(ultima().filhos[0].textContent, '3 arquivos novos');
});

test('Nome com HTML aparece como texto na linha de sistema', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  chat.mostrarArquivosNovos([{ id: 'h', name: '<img src=x onerror=alert(1)>', size: 1 }]);
  assert.strictEqual(ultima().filhos[0].textContent, 'Novo arquivo: <img src=x onerror=alert(1)>');
});

test('Lista vazia não cria aviso', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  const antes = elementos.chatMessages.filhos.length;
  chat.mostrarArquivosNovos([]);
  assert.strictEqual(elementos.chatMessages.filhos.length, antes);
});

test('Mão abaixada pelo professor vira uma linha de sistema com o ícone da mão', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  chat.mostrarMaoAbaixada();
  assert.strictEqual(ultima().className, 'chat-event mao');
  assert.strictEqual(ultima().filhos[0].textContent, 'O professor abaixou sua mão');
});

// MARK: - Mensagem fixada

test('Fixar mostra o cartão no topo, com os links clicáveis', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  const novidade = chat.fixar('Portal do aluno: www.portal.edu.br');

  assert.strictEqual(novidade, true);
  assert.strictEqual(elementos.chatPinned.hidden, false);
  const [texto, link] = elementos.chatPinnedText.filhos;
  assert.strictEqual(texto.textContent, 'Portal do aluno: ');
  assert.strictEqual(link.href, 'http://www.portal.edu.br');
});

test('Trocar a fixada substitui o texto; a mesma de novo não é novidade', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  chat.fixar('primeira');
  assert.strictEqual(chat.fixar('segunda'), true);
  assert.strictEqual(elementos.chatPinnedText.filhos.length, 1);
  assert.strictEqual(elementos.chatPinnedText.filhos[0].textContent, 'segunda');
  assert.strictEqual(chat.fixar('segunda'), false, 'repetida (ex.: reconexão) não conta');
});

test('Fixada nula ou vazia desafixa', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  chat.fixar('algo');
  assert.strictEqual(chat.fixar(null), false);
  assert.strictEqual(elementos.chatPinned.hidden, true);

  chat.fixar('algo');
  chat.fixar('   ');
  assert.strictEqual(elementos.chatPinned.hidden, true);
});

test('"Ver mais" aparece só quando o texto passa de 3 linhas, e abre e fecha', () => {
  // Os ChatManagers dos testes anteriores também ouvem este botão: só o deste teste conta.
  elementos.chatPinnedMore.listeners = {};
  const chat = new ChatManager(() => true, () => 'Ana');
  elementos.chatPinnedText.clientHeight = 60;
  elementos.chatPinnedText.scrollHeight = 60;
  chat.fixar('curta');
  assert.strictEqual(elementos.chatPinnedMore.hidden, true, 'cabe em 3 linhas');

  elementos.chatPinnedText.scrollHeight = 140;
  chat.fixar('comprida '.repeat(40));
  assert.strictEqual(elementos.chatPinnedMore.hidden, false);
  assert.strictEqual(elementos.chatPinnedMore.textContent, 'Ver mais');

  elementos.chatPinnedMore.dispatch('click');
  assert.ok(elementos.chatPinned.classList.contains('expandida'));
  assert.strictEqual(elementos.chatPinnedMore.textContent, 'Ver menos');
  assert.strictEqual(elementos.chatPinnedMore.attrs['aria-expanded'], 'true');

  elementos.chatPinnedMore.dispatch('click');
  assert.ok(!elementos.chatPinned.classList.contains('expandida'));
});
