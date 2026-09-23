import test from 'node:test';
import assert from 'node:assert';

function criarElemento(tag = 'div') {
  const el = {
    tagName: tag, className: '', textContent: '', hidden: false, href: '', filhos: [], attrs: {},
    listeners: {}, parentNode: null,
    get firstChild() { return el.filhos[0] || null; },
    appendChild(f) { f.parentNode = el; el.filhos.push(f); },
    removeChild(f) { el.filhos.splice(el.filhos.indexOf(f), 1); f.parentNode = null; },
    setAttribute(n, v) { el.attrs[n] = v; },
    addEventListener(evt, fn) { (el.listeners[evt] ||= []).push(fn); },
    dispatch(evt) { (el.listeners[evt] || []).forEach((fn) => fn()); },
    querySelector(sel) {
      const classe = sel.replace('.', '');
      const achar = (n) => (n.className === classe ? n : n.filhos.map(achar).find(Boolean));
      return el.filhos.map(achar).find(Boolean) || null;
    }
  };
  return el;
}

const elementos = { filesSection: criarElemento('section'), filesList: criarElemento('ul') };
globalThis.document = {
  getElementById: (id) => elementos[id] ?? null,
  createElement: (tag) => criarElemento(tag)
};

const { FilesList, formatarTamanho } = await import('../js/files-list.js');

test('Sem arquivos, a seção fica escondida', () => {
  const lista = new FilesList();
  lista.render([]);
  assert.strictEqual(elementos.filesSection.hidden, true);
});

test('Cada arquivo vira um link de download com nome e tamanho', () => {
  const lista = new FilesList();
  lista.render([{ id: 'abc-1', name: 'Apostila.pdf', size: 1500 }]);

  assert.strictEqual(elementos.filesSection.hidden, false);
  const link = elementos.filesList.filhos[0].filhos[0];
  assert.strictEqual(link.href, '/arquivos/abc-1');
  assert.strictEqual(link.attrs.download, 'Apostila.pdf');
  assert.strictEqual(link.filhos[0].textContent, 'Apostila.pdf');
  assert.strictEqual(link.filhos[1].textContent, '1,5 KB');
});

test('Nome de arquivo com HTML aparece como texto, não vira código na página', () => {
  const lista = new FilesList();
  const nome = '<img src=x onerror=alert(1)>.txt';
  lista.render([{ id: 'x', name: nome, size: 10 }]);
  const span = elementos.filesList.filhos[0].filhos[0].filhos[0];
  assert.strictEqual(span.textContent, nome);
  assert.strictEqual(span.innerHTML, undefined, 'innerHTML nunca é usado');
});

test('Re-renderizar troca a lista em vez de acumular', () => {
  const lista = new FilesList();
  lista.render([{ id: 'a', name: 'a', size: 1 }, { id: 'b', name: 'b', size: 1 }]);
  lista.render([{ id: 'b', name: 'b', size: 1 }]);
  assert.strictEqual(elementos.filesList.filhos.length, 1);
});

test('Só arquivo novo gera aviso; a lista de quem acabou de entrar não', () => {
  const avisos = [];
  const lista = new FilesList({ onNovidade: (novos) => avisos.push(novos.map((a) => a.id)) });
  lista.render([{ id: 'a', name: 'a', size: 1 }]);
  assert.strictEqual(avisos.length, 0, 'primeira lista não é novidade');
  lista.render([{ id: 'a', name: 'a', size: 1 }, { id: 'b', name: 'b', size: 1 }]);
  assert.deepStrictEqual(avisos, [['b']]);
  lista.render([{ id: 'b', name: 'b', size: 1 }]);
  assert.strictEqual(avisos.length, 1, 'tirar um arquivo não é novidade');
});

test('Tamanhos legíveis em português', () => {
  assert.strictEqual(formatarTamanho(512), '512 B');
  assert.strictEqual(formatarTamanho(3_000_000), '3 MB', 'o mesmo número que o Mac mostra');
  assert.strictEqual(formatarTamanho(3_400_000), '3,4 MB');
  assert.strictEqual(formatarTamanho(250_000_000), '250 MB');
  assert.strictEqual(formatarTamanho(1_200_000_000), '1,2 GB');
});

test('Arquivo que chega durante a aula ganha a etiqueta Novo; os da entrada não', () => {
  const lista = new FilesList();
  lista.render([{ id: 'velho', name: 'velho.pdf', size: 1 }]);
  lista.render([{ id: 'velho', name: 'velho.pdf', size: 1 }, { id: 'novo', name: 'novo.pdf', size: 1 }]);

  const [itemVelho, itemNovo] = elementos.filesList.filhos;
  assert.strictEqual(itemVelho.querySelector('.file-new'), null, 'a lista da entrada não é novidade');
  assert.strictEqual(itemNovo.querySelector('.file-new').textContent, 'Novo');
});

test('A etiqueta Novo some quando o aluno baixa o arquivo, e não volta', () => {
  const lista = new FilesList();
  lista.render([]);
  lista.render([{ id: 'n', name: 'n.pdf', size: 1 }]);
  const item = elementos.filesList.filhos[0];
  const link = item.filhos[0];

  link.dispatch('click');
  assert.strictEqual(item.querySelector('.file-new'), null, 'baixou: a etiqueta sai');

  lista.render([{ id: 'n', name: 'n.pdf', size: 1 }, { id: 'm', name: 'm.pdf', size: 1 }]);
  assert.strictEqual(elementos.filesList.filhos[0].querySelector('.file-new'), null, 're-renderizar não traz de volta');
  assert.ok(elementos.filesList.filhos[1].querySelector('.file-new'), 'o outro arquivo novo mantém a sua');
});
