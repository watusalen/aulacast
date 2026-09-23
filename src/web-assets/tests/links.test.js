import test from 'node:test';
import assert from 'node:assert';
import { partirEmLinks, escreverComLinks } from '../js/links.js';

/** Só os links, na ordem, para comparar de uma vez. */
function links(texto) {
  return partirEmLinks(texto).filter((p) => p.tipo === 'link').map((p) => p.href);
}

test('http, https e www viram link; www ganha http://', () => {
  assert.deepStrictEqual(links('Veja http://a.com, https://b.com/x e www.c.com.br/y'), [
    'http://a.com', 'https://b.com/x', 'http://www.c.com.br/y'
  ]);
});

test('A pontuação da frase não gruda no link', () => {
  assert.deepStrictEqual(links('veja https://x.com.'), ['https://x.com']);
  assert.deepStrictEqual(links('é https://x.com/a?b=1, depois'), ['https://x.com/a?b=1']);
  assert.deepStrictEqual(links('abra https://x.com!'), ['https://x.com']);
  assert.deepStrictEqual(links('"https://x.com"'), ['https://x.com']);
  assert.deepStrictEqual(links('link: https://x.com...'), ['https://x.com']);
});

test('Parêntese de fora sai; o que faz parte do endereço fica', () => {
  assert.deepStrictEqual(links('(veja https://x.com/a)'), ['https://x.com/a']);
  assert.deepStrictEqual(links('https://pt.wikipedia.org/wiki/Java_(linguagem)'),
    ['https://pt.wikipedia.org/wiki/Java_(linguagem)']);
  assert.deepStrictEqual(links('(ver https://pt.wikipedia.org/wiki/Java_(linguagem)).'),
    ['https://pt.wikipedia.org/wiki/Java_(linguagem)']);
});

test('Outros esquemas ficam como texto: um link do chat não pode executar nada', () => {
  assert.deepStrictEqual(links('javascript:alert(1)'), []);
  assert.deepStrictEqual(links('data:text/html,<b>oi</b>'), []);
  assert.deepStrictEqual(links('file:///etc/passwd'), []);
  assert.deepStrictEqual(links('ftp://x.com'), []);
});

test('Só o prefixo não é link, e "www" no meio de uma palavra também não', () => {
  assert.deepStrictEqual(links('digite https:// e o endereço'), []);
  assert.deepStrictEqual(links('abcwww.x.com'), []);
});

test('O texto em volta é preservado, na ordem', () => {
  const pedacos = partirEmLinks('Portal: https://portal.edu.br. Até!');
  assert.deepStrictEqual(pedacos, [
    { tipo: 'texto', texto: 'Portal: ' },
    { tipo: 'link', texto: 'https://portal.edu.br', href: 'https://portal.edu.br' },
    { tipo: 'texto', texto: '. Até!' }
  ]);
});

test('Texto sem link vira um pedaço só; vazio ou nulo não quebra', () => {
  assert.deepStrictEqual(partirEmLinks('bom dia'), [{ tipo: 'texto', texto: 'bom dia' }]);
  assert.deepStrictEqual(partirEmLinks(''), []);
  assert.deepStrictEqual(partirEmLinks(null), []);
});

function criarDoc() {
  const criar = (tipo) => {
    const el = {
      tipo, filhos: [], attrs: {}, textContent: '', href: '', target: '', rel: '',
      get firstChild() { return el.filhos[0] || null; },
      appendChild(f) { el.filhos.push(f); },
      removeChild(f) { el.filhos.splice(el.filhos.indexOf(f), 1); }
    };
    return el;
  };
  return {
    createElement: (tag) => criar(tag),
    createTextNode: (texto) => ({ tipo: '#texto', textContent: texto })
  };
}

test('escreverComLinks monta <a> com textContent, nova aba e noopener', () => {
  const doc = criarDoc();
  const alvo = doc.createElement('div');
  escreverComLinks(alvo, 'Leia <b>isto</b>: www.x.com/<script>', doc);

  const [antes, link] = alvo.filhos;
  assert.strictEqual(antes.tipo, '#texto');
  assert.strictEqual(antes.textContent, 'Leia <b>isto</b>: ', 'HTML da mensagem fica como texto');
  assert.strictEqual(link.tipo, 'a');
  assert.strictEqual(link.href, 'http://www.x.com/');
  assert.strictEqual(link.textContent, 'www.x.com/');
  assert.strictEqual(link.target, '_blank');
  assert.strictEqual(link.rel, 'noopener noreferrer');
  assert.strictEqual(link.innerHTML, undefined, 'innerHTML nunca é usado');
});

test('escreverComLinks troca o conteúdo anterior em vez de acumular', () => {
  const doc = criarDoc();
  const alvo = doc.createElement('p');
  escreverComLinks(alvo, 'https://a.com', doc);
  escreverComLinks(alvo, 'só texto', doc);
  assert.strictEqual(alvo.filhos.length, 1);
  assert.strictEqual(alvo.filhos[0].textContent, 'só texto');
});
