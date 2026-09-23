import test from 'node:test';
import assert from 'node:assert';

/**
 * DOM mínimo para exercitar o ChatManager real fora do navegador.
 * Antes, este arquivo declarava uma função de formatação dentro do próprio teste e
 * verificava um formato que o aplicativo nunca produziu — não cobria nada.
 */
function montarDomFalso() {
  const criarElemento = () => {
    const el = {
      className: '',
      textContent: '',
      value: '',
      filhos: [],
      scrollTop: 0,
      scrollHeight: 100,
      hidden: false,
      disabled: false,
      attrs: {},
      href: '',
      setAttribute(nome, valor) { this.attrs[nome] = valor; },
      appendChild(filho) { this.filhos.push(filho); },
      addEventListener() {},
      blur() {}
    };
    return el;
  };

  const elementos = {
    chatForm: criarElemento(),
    chatMessageInput: criarElemento(),
    chatMessages: criarElemento(),
    chatSendBtn: criarElemento()
  };

  globalThis.document = {
    getElementById: (id) => elementos[id] ?? null,
    createElement: () => criarElemento()
  };

  return elementos;
}

const elementos = montarDomFalso();
const { ChatManager } = await import('../js/chat-manager.js');

/** Texto do autor da última mensagem inserida no histórico. */
function autorDaUltimaMensagem(chatMessages) {
  const bolha = chatMessages.filhos[chatMessages.filhos.length - 1];
  return bolha.filhos[0].textContent;
}

function classeDaUltimaMensagem(chatMessages) {
  return chatMessages.filhos[chatMessages.filhos.length - 1].className;
}

test('Mensagem do professor mostra o remetente do servidor sem "Prof. Professor"', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  // É isto que o servidor manda de verdade (ChatManagerService).
  chat.appendMessage('Professor', 'Aumentei a fonte do terminal.', true);

  const autor = autorDaUltimaMensagem(elementos.chatMessages);
  assert.match(autor, /^Professor · \d{2}:\d{2}$/);
  assert.match(classeDaUltimaMensagem(elementos.chatMessages), /prof/);
});

test('Mensagem de aluno não recebe prefixo de professor', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  chat.appendMessage('Carlos Eduardo', 'Dá pra aumentar a fonte?', false);

  const autor = autorDaUltimaMensagem(elementos.chatMessages);
  assert.match(autor, /^Carlos Eduardo · \d{2}:\d{2}$/);
  assert.ok(!autor.includes('Prof.'));
});

test('A própria mensagem do aluno é marcada como "own"', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  chat.appendMessage('Ana Beatriz', 'Deu certo aqui!', false);

  assert.match(classeDaUltimaMensagem(elementos.chatMessages), /own/);
});

test('Mensagem do professor nunca é marcada como "own"', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  // Mesmo que o nome coincida com o do aluno, ser do professor tem precedência.
  chat.appendMessage('Ana Beatriz', 'Resposta do professor.', true);

  assert.ok(!classeDaUltimaMensagem(elementos.chatMessages).includes('own'));
});

test('O texto da mensagem é preservado', () => {
  const chat = new ChatManager(() => {}, () => 'Ana Beatriz');
  const texto = 'Qual a diferença entre let e var?';
  chat.appendMessage('Carlos Eduardo', texto, false);

  const bolha = elementos.chatMessages.filhos[elementos.chatMessages.filhos.length - 1];
  assert.strictEqual(bolha.filhos[1].textContent, texto);
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
  assert.match(classeDaUltimaMensagem(elementos.chatMessages), /system/);
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

test('Arquivo novo vira um cartão com título e o arquivo como link', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  const antes = elementos.chatMessages.filhos.length;
  chat.mostrarArquivosNovos([{ id: 'x1', name: 'Lista 3.pdf', size: 184000 }]);

  const cartao = elementos.chatMessages.filhos[antes];
  assert.strictEqual(cartao.className, 'chat-notice');
  assert.strictEqual(cartao.filhos[0].filhos[0].textContent, 'Novo arquivo');
  assert.match(cartao.filhos[0].filhos[1].textContent, /^\d{2}:\d{2}$/, 'a hora fica à parte, alinhada à direita');
  const link = cartao.filhos[1].filhos[0].filhos[0];
  assert.strictEqual(link.href, '/arquivos/x1');
  assert.strictEqual(link.filhos[0].textContent, 'Lista 3.pdf');
  assert.strictEqual(link.filhos[1].textContent, '184 KB');
});

test('Vários arquivos: um por linha, com o nome inteiro ao passar o mouse', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  const longo = 'Apostila completa de Estruturas de Dados – Capítulo 4 (versão revisada).pdf';
  chat.mostrarArquivosNovos([
    { id: 'a', name: 'a.zip', size: 10 },
    { id: 'b', name: longo, size: 1200000 },
    { id: 'c', name: '<b>c</b>.txt', size: 5 }
  ]);
  const cartao = elementos.chatMessages.filhos[elementos.chatMessages.filhos.length - 1];
  assert.strictEqual(cartao.filhos[0].filhos[0].textContent, 'Novos arquivos (3)');
  const linhas = cartao.filhos[1].filhos;
  assert.strictEqual(linhas.length, 3, 'um item por arquivo, sem juntar nomes por vírgula');
  assert.strictEqual(linhas[1].filhos[0].attrs.title, longo);
  assert.strictEqual(linhas[2].filhos[0].filhos[0].textContent, '<b>c</b>.txt', 'nome vai como texto, não como HTML');
});

test('Lista vazia não cria cartão', () => {
  const chat = new ChatManager(() => true, () => 'Ana');
  const antes = elementos.chatMessages.filhos.length;
  chat.mostrarArquivosNovos([]);
  assert.strictEqual(elementos.chatMessages.filhos.length, antes);
});
