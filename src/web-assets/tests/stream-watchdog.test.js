import test from 'node:test';
import assert from 'node:assert';
import { STREAM_RETRY_BASE_MS, STREAM_RETRY_MAX_MS } from '../js/config.js';

/** <img> mínimo para exercitar o watchdog fora do navegador. */
function fakeImg() {
  const listeners = {};
  const attrs = {};
  return {
    listeners,
    addEventListener(evt, fn) { (listeners[evt] ||= []).push(fn); },
    dispatch(evt) { (listeners[evt] || []).forEach(fn => fn()); },
    getAttribute(name) { return attrs[name] ?? null; },
    removeAttribute(name) { delete attrs[name]; },
    set src(v) { attrs.src = v; },
    get src() { return attrs.src ?? ''; }
  };
}

// O watchdog usa window.location para montar a URL do stream.
globalThis.window = { location: { protocol: 'http:', host: '127.0.0.1:8080' } };
const { StreamWatchdog } = await import('../js/stream-watchdog.js');

test('start() conecta o stream com parametro anti-cache', () => {
  const img = fakeImg();
  const wd = new StreamWatchdog(img);
  wd.start();

  assert.match(img.src, /^http:\/\/127\.0\.0\.1:8080\/stream\?t=\d+$/);
  wd.stop();
});

test('queda do stream (error) agenda nova tentativa', () => {
  const img = fakeImg();
  const tentativas = [];
  const wd = new StreamWatchdog(img, { onRetry: (n, motivo) => tentativas.push({ n, motivo }) });

  wd.start();
  img.dispatch('error');

  assert.strictEqual(tentativas.length, 1);
  assert.strictEqual(tentativas[0].n, 1);
  assert.strictEqual(tentativas[0].motivo, 'error');
  wd.stop();
});

test('o load do primeiro quadro NAO derruba o stream', () => {
  const img = fakeImg();
  const tentativas = [];
  const wd = new StreamWatchdog(img, { onRetry: (n, motivo) => tentativas.push({ n, motivo }) });

  wd.start();
  const srcInicial = img.src;

  // Num multipart/x-mixed-replace o `load` dispara na PRIMEIRA parte — Chrome e Safari
  // fazem isso, o Firefox dispara a cada quadro. Tratar isso como fim do stream fazia o
  // vigia reconectar em ciclo e a imagem do aluno piscava sem parar.
  img.dispatch('load');
  img.dispatch('load');

  assert.strictEqual(tentativas.length, 0, 'load nao conta como queda');
  assert.strictEqual(img.src, srcInicial, 'o stream segue no ar, sem reconectar');

  wd.stop();
});

test('stop() encerra de proposito e nao dispara novas tentativas', () => {
  const img = fakeImg();
  const tentativas = [];
  const wd = new StreamWatchdog(img, { onRetry: (n) => tentativas.push(n) });

  wd.start();
  wd.stop();
  img.dispatch('error');
  img.dispatch('load');

  assert.strictEqual(tentativas.length, 0);
  assert.strictEqual(img.getAttribute('src'), null, 'src deve ser limpo ao parar');
});

test('intervalo entre tentativas cresce mas respeita o teto', () => {
  assert.ok(STREAM_RETRY_BASE_MS > 0);
  assert.ok(STREAM_RETRY_MAX_MS >= STREAM_RETRY_BASE_MS);

  const calcular = (tentativa) =>
    Math.min(STREAM_RETRY_BASE_MS * Math.pow(2, tentativa - 1), STREAM_RETRY_MAX_MS);

  assert.strictEqual(calcular(1), STREAM_RETRY_BASE_MS);
  assert.ok(calcular(2) > calcular(1));
  assert.strictEqual(calcular(50), STREAM_RETRY_MAX_MS);
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
  img.dispatch('load');
  assert.strictEqual(wd.attempts, 0);

  wd.stop();
});
