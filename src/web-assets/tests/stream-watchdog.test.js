import test, { mock } from 'node:test';
import assert from 'node:assert';
import { STREAM_RETRY_BASE_MS, STREAM_RETRY_MAX_MS } from '../js/config.js';

/** <canvas> mínimo: registra o que foi pintado. */
function fakeCanvas() {
  const pinturas = [];
  return {
    pinturas,
    className: '',
    hidden: false,
    width: 300,
    height: 150,
    attrs: {},
    setAttribute(n, v) { this.attrs[n] = v; },
    getContext() { return { drawImage: (img, ...args) => pinturas.push({ img, args }) }; }
  };
}

/**
 * <img> mínimo para exercitar o watchdog fora do navegador.
 *
 * `naturalWidth` começa em 0 (sem imagem); o teste o põe em 1280 para simular um quadro
 * na tela e de volta em 0 para simular a imagem quebrada depois de um `error`.
 */
function fakeImg() {
  const listeners = {};
  const attrs = {};
  const filhos = [];
  const img = {
    listeners,
    trocasDeSrc: 0,
    naturalWidth: 0,
    naturalHeight: 0,
    complete: true,
    style: {},
    ownerDocument: { createElement: (tag) => { assert.strictEqual(tag, 'canvas'); return fakeCanvas(); } },
    addEventListener(evt, fn) { (listeners[evt] ||= []).push(fn); },
    dispatch(evt) { (listeners[evt] || []).forEach(fn => fn()); },
    getAttribute(name) { return attrs[name] ?? null; },
    // Sem src, o navegador descarta a imagem.
    removeAttribute(name) { delete attrs[name]; if (name === 'src') img.semQuadro(); },
    set src(v) { attrs.src = v; img.trocasDeSrc += 1; },
    get src() { return attrs.src ?? ''; },
    /** Simula um quadro de 1280x720 exibido. */
    comQuadro() { img.naturalWidth = 1280; img.naturalHeight = 720; return img; },
    semQuadro() { img.naturalWidth = 0; img.naturalHeight = 0; return img; }
  };
  img.nextSibling = null;
  img.parentNode = {
    filhos,
    insertBefore(novo, ref) {
      assert.strictEqual(ref, img.nextSibling);
      filhos.push(novo);
    }
  };
  return img;
}

// O watchdog usa window.location para montar a URL do stream.
globalThis.window = { location: { protocol: 'http:', host: '127.0.0.1:8080' } };
const { StreamWatchdog, CLASSE_QUADRO_CONGELADO } = await import('../js/stream-watchdog.js');

test('start() conecta o stream com parametro anti-cache', () => {
  const img = fakeImg();
  const wd = new StreamWatchdog(img);
  wd.start();

  assert.match(img.src, /^http:\/\/127\.0\.0\.1:8080\/stream\?t=\d+$/);
  wd.stop();
});

test('start() e idempotente: com o stream de pe, nao troca o src', () => {
  const img = fakeImg();
  const wd = new StreamWatchdog(img);

  // A pagina chamava start() ao conectar o WebSocket e de novo ao saber que a aula
  // estava ao vivo: cada chamada reiniciava o video.
  wd.start();
  img.comQuadro().dispatch('load');
  wd.start();
  wd.start();

  assert.strictEqual(img.trocasDeSrc, 1);
  wd.stop();
});

test('start() durante a espera de nova tentativa reconecta na hora', () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const img = fakeImg();
    const wd = new StreamWatchdog(img);
    wd.start();
    img.dispatch('error');
    assert.strictEqual(img.trocasDeSrc, 1, 'a tentativa ficou agendada');

    // O WebSocket voltou: quem chama start() sabe que o servidor esta de pe.
    wd.start();
    assert.strictEqual(img.trocasDeSrc, 2);

    // E a tentativa antiga nao dispara depois por cima.
    mock.timers.tick(STREAM_RETRY_MAX_MS);
    assert.strictEqual(img.trocasDeSrc, 2);
    wd.stop();
  } finally {
    mock.timers.reset();
  }
});

test('queda do stream (error) agenda nova tentativa e avisa o estado', () => {
  const img = fakeImg();
  const tentativas = [];
  const estados = [];
  const wd = new StreamWatchdog(img, {
    onRetry: (n, motivo) => tentativas.push({ n, motivo }),
    onEstado: (e) => estados.push(e)
  });

  wd.start();
  img.dispatch('error');

  assert.strictEqual(tentativas.length, 1);
  assert.strictEqual(tentativas[0].n, 1);
  assert.strictEqual(tentativas[0].motivo, 'error');
  assert.deepStrictEqual(estados, ['reconectando']);
  wd.stop();
  assert.deepStrictEqual(estados, ['reconectando', 'parado']);
});

test('o load do primeiro quadro NAO derruba o stream', () => {
  const img = fakeImg();
  const tentativas = [];
  const estados = [];
  const wd = new StreamWatchdog(img, {
    onRetry: (n, motivo) => tentativas.push({ n, motivo }),
    onEstado: (e) => estados.push(e)
  });

  wd.start();
  const srcInicial = img.src;

  // Num multipart/x-mixed-replace o `load` dispara na PRIMEIRA parte — Chrome e Safari
  // fazem isso, o Firefox dispara a cada quadro. Tratar isso como fim do stream fazia o
  // vigia reconectar em ciclo e a imagem do aluno piscava sem parar.
  img.comQuadro().dispatch('load');
  img.dispatch('load');
  img.dispatch('load');

  assert.strictEqual(tentativas.length, 0, 'load nao conta como queda');
  assert.strictEqual(img.src, srcInicial, 'o stream segue no ar, sem reconectar');
  assert.deepStrictEqual(estados, ['ao-vivo'], 'o estado so e avisado quando muda');

  wd.stop();
});

test('stop() encerra de proposito, limpa a imagem e nao dispara novas tentativas', () => {
  const img = fakeImg();
  const tentativas = [];
  const wd = new StreamWatchdog(img, { onRetry: (n) => tentativas.push(n) });

  wd.start();
  img.comQuadro().dispatch('load');
  wd.stop();
  img.dispatch('error');
  img.dispatch('load');

  assert.strictEqual(tentativas.length, 0);
  assert.strictEqual(img.getAttribute('src'), null, 'src deve ser limpo ao parar');
  assert.strictEqual(img.parentNode.filhos[0].hidden, true, 'aula encerrada nao deixa quadro');
});

test('intervalo entre tentativas dobra a cada queda e respeita o teto', () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const img = fakeImg();
    const wd = new StreamWatchdog(img);
    wd.start();

    const esperas = [];
    for (let i = 0; i < 6; i++) {
      const antes = img.trocasDeSrc;
      img.dispatch('error');
      let esperou = 0;
      while (img.trocasDeSrc === antes) {
        mock.timers.tick(100);
        esperou += 100;
        assert.ok(esperou <= STREAM_RETRY_MAX_MS, 'nunca espera mais que o teto');
      }
      esperas.push(esperou);
    }

    assert.strictEqual(esperas[0], STREAM_RETRY_BASE_MS);
    assert.strictEqual(esperas[1], STREAM_RETRY_BASE_MS * 2);
    assert.strictEqual(esperas[2], STREAM_RETRY_BASE_MS * 4);
    assert.strictEqual(esperas[5], Math.min(STREAM_RETRY_BASE_MS * 32, STREAM_RETRY_MAX_MS));
    wd.stop();
  } finally {
    mock.timers.reset();
  }
});

test('imagem chegando zera o intervalo de reconexao', () => {
  const img = fakeImg();
  const wd = new StreamWatchdog(img);
  wd.start();

  // Duas quedas seguidas empurram o intervalo para cima.
  img.dispatch('error');
  img.dispatch('error');
  assert.ok(wd.attempts >= 2, 'as tentativas acumulam durante a queda');

  // Voltou a chegar imagem: a proxima queda tem de recomecar do intervalo curto, senao
  // uma oscilacao no comeco da aula deixa o aluno esperando o teto de 10 s ate o fim.
  wd.connect();
  img.dispatch('load');
  assert.strictEqual(wd.attempts, 0);

  wd.stop();
});

test('cria um canvas escondido logo depois da img, com a classe do CSS', () => {
  const img = fakeImg();
  new StreamWatchdog(img);

  const [canvas] = img.parentNode.filhos;
  assert.ok(canvas, 'o canvas foi inserido');
  assert.strictEqual(canvas.className, CLASSE_QUADRO_CONGELADO);
  assert.strictEqual(CLASSE_QUADRO_CONGELADO, 'stream-congelado');
  assert.strictEqual(canvas.hidden, true);
  assert.strictEqual(canvas.attrs['aria-hidden'], 'true');
});

test('congelar() mantem o ultimo quadro e o start() seguinte retoma sem piscar', () => {
  const img = fakeImg();
  const estados = [];
  const tentativas = [];
  const wd = new StreamWatchdog(img, {
    onEstado: (e) => estados.push(e),
    onRetry: (n) => tentativas.push(n)
  });
  const [canvas] = img.parentNode.filhos;

  wd.start();
  img.comQuadro().dispatch('load');

  // O WebSocket caiu.
  wd.congelar();
  assert.strictEqual(canvas.pinturas.length, 1, 'o quadro atual foi pintado uma vez');
  assert.strictEqual(canvas.pinturas[0].img, img);
  assert.strictEqual(canvas.width, 1280);
  assert.strictEqual(canvas.height, 720);
  assert.strictEqual(canvas.hidden, false, 'o quadro congelado fica na tela');
  assert.strictEqual(img.style.visibility, 'hidden', 'a img vazia por baixo nao aparece');
  assert.strictEqual(img.getAttribute('src'), null, 'a conexao de video foi solta');

  // Soltar o src pode disparar `error`: nao e queda, ninguem quer o stream agora.
  img.semQuadro().dispatch('error');
  assert.strictEqual(tentativas.length, 0);

  // O WebSocket voltou.
  wd.start();
  assert.match(img.src, /\/stream\?t=\d+$/);
  assert.strictEqual(canvas.hidden, false, 'segue congelado ate o primeiro quadro novo');
  assert.strictEqual(canvas.pinturas.length, 1, 'nao repinta a partir de uma img vazia');

  img.comQuadro().dispatch('load');
  assert.strictEqual(canvas.hidden, true, 'o quadro novo assume');
  assert.strictEqual(img.style.visibility, '');
  assert.strictEqual(canvas.width, 0, 'a memoria do quadro e solta');
  assert.deepStrictEqual(estados, ['ao-vivo', 'parado', 'ao-vivo']);
  wd.stop();
});

test('queda do video: o ultimo quadro cobre a img durante todas as tentativas', () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const img = fakeImg();
    const wd = new StreamWatchdog(img);
    const [canvas] = img.parentNode.filhos;
    wd.start();
    img.comQuadro().dispatch('load');

    // O WebSocket cai (o servidor reiniciou) e volta antes do video: as primeiras
    // tentativas falham e a img fica sem imagem (Chrome: vazia; WebKit: branca).
    wd.congelar();
    wd.start();
    img.dispatch('error');
    mock.timers.tick(STREAM_RETRY_BASE_MS);
    img.dispatch('error');
    mock.timers.tick(STREAM_RETRY_BASE_MS * 2);
    assert.strictEqual(canvas.hidden, false, 'o quadro congelado atravessa as tentativas');
    assert.strictEqual(canvas.pinturas.length, 1, 'pintado uma vez so, antes de soltar o src');
    assert.strictEqual(img.style.visibility, 'hidden');

    img.comQuadro().dispatch('load');
    assert.strictEqual(canvas.hidden, true);
    assert.strictEqual(img.style.visibility, '');
    wd.stop();
  } finally {
    mock.timers.reset();
  }
});

test('img ja quebrada e sem quadro: nada de canvas vazio por cima', () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const img = fakeImg();
    const wd = new StreamWatchdog(img);
    const [canvas] = img.parentNode.filhos;
    wd.start();
    img.semQuadro().dispatch('error');
    mock.timers.tick(STREAM_RETRY_BASE_MS);

    assert.strictEqual(canvas.pinturas.length, 0);
    assert.strictEqual(canvas.hidden, true);
    wd.stop();
  } finally {
    mock.timers.reset();
  }
});

test('troca de src pintando o quadro que ainda esta na img', () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const img = fakeImg();
    const wd = new StreamWatchdog(img);
    const [canvas] = img.parentNode.filhos;
    wd.start();
    img.comQuadro().dispatch('load');

    // Um `error` que chega com o quadro ainda exibido (o pedido pendente falhou, mas o
    // navegador ainda nao descartou a imagem): a proxima tentativa pinta esse quadro.
    img.dispatch('error');
    mock.timers.tick(STREAM_RETRY_BASE_MS);
    assert.strictEqual(canvas.pinturas.length, 1);
    assert.strictEqual(canvas.hidden, false);
    wd.stop();
  } finally {
    mock.timers.reset();
  }
});

test('congelar() sem quadro nenhum nao mostra canvas vazio', () => {
  const img = fakeImg();
  const wd = new StreamWatchdog(img);
  const [canvas] = img.parentNode.filhos;

  wd.start();
  wd.congelar();

  assert.strictEqual(canvas.pinturas.length, 0);
  assert.strictEqual(canvas.hidden, true);
});
