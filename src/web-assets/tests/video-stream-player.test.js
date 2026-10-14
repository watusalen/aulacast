import test from 'node:test';
import assert from 'node:assert';
import { VideoStreamPlayer, mediaSourceSuportado } from '../js/video-stream-player.js';

/** <video> mínimo para exercitar o player fora do navegador. */
function fakeVideo() {
  const listeners = {};
  const attrs = {};
  return {
    listeners,
    classes: new Set(),
    // `classList` de verdade é montado em `criarVideo()`, que precisa da referência ao
    // próprio objeto (uma arrow function aqui dentro não teria acesso a ele antes de existir).
    classList: null,
    addEventListener(evt, fn) { (listeners[evt] ||= []).push(fn); },
    dispatch(evt, dados) { (listeners[evt] || []).forEach((fn) => fn(dados)); },
    getAttribute(nome) { return attrs[nome] ?? null; },
    setAttribute(nome, valor) { attrs[nome] = valor; },
    removeAttribute(nome) { delete attrs[nome]; },
    set src(v) { attrs.src = v; },
    get src() { return attrs.src; }
  };
}

/** Corrige o `classList` acima com acesso ao próprio objeto (sem depender de `this` de arrow). */
function criarVideo() {
  const video = fakeVideo();
  video.classList = {
    add: (c) => video.classes.add(c),
    remove: (c) => video.classes.delete(c),
    contains: (c) => video.classes.has(c)
  };
  return video;
}

/** `SourceBuffer` mínimo: registra o que foi anexado e simula `updating`. */
function fakeSourceBuffer() {
  const listeners = {};
  return {
    updating: false,
    anexados: [],
    addEventListener(evt, fn) { (listeners[evt] ||= []).push(fn); },
    dispatch(evt) { (listeners[evt] || []).forEach((fn) => fn()); },
    appendBuffer(pedaco) { this.anexados.push(pedaco); }
  };
}

/**
 * `MediaSource` mínima: dispara `sourceopen` só quando o teste mandar.
 *
 * `instanciaMaisRecente` fica na classe retornada (`FakeMS`, capturada por closure), não na
 * fábrica: os testes fazem `class MSComSuporte extends MSClasse { ... }` e instanciam a
 * subclasse — o construtor herdado ainda referencia `FakeMS` pelo escopo léxico, então
 * `MSClasse.instanciaMaisRecente` (o que os testes leem) é atualizado mesmo quando quem foi
 * de fato construído é a subclasse.
 */
function fakeMediaSourceClasse(sourceBuffer, { falharAoAdicionar } = {}) {
  class FakeMS {
    constructor() {
      this.readyState = 'open';
      this.listeners = {};
      this.sourceBufferRemovido = false;
      FakeMS.instanciaMaisRecente = this;
    }
    addEventListener(evt, fn) { (this.listeners[evt] ||= []).push(fn); }
    dispatch(evt) { (this.listeners[evt] || []).forEach((fn) => fn()); }
    addSourceBuffer() {
      if (falharAoAdicionar) throw new Error('tipo não suportado');
      return sourceBuffer;
    }
    removeSourceBuffer() { this.sourceBufferRemovido = true; }
    endOfStream() { this.readyState = 'ended'; }
  }
  return FakeMS;
}

/**
 * Fábrica de `fetch` cujo corpo entrega os pedaços dados, um por `read()`.
 *
 * Por padrão termina com `done: true` depois do último pedaço (simula o servidor fechando a
 * conexão). Com `travarNoFim`, em vez disso o `read()` seguinte nunca resolve — simula uma
 * conexão que só ainda não tem o PRÓXIMO quadro, sem fechar; útil para testar comportamento
 * que não deve ser confundido com queda de conexão (que zera a fila de pedaços pendentes).
 */
function fetchComPedacos(pedacos, { falhaNoFetch, travarNoFim } = {}) {
  let indice = 0;
  return async () => {
    if (falhaNoFetch) throw new Error('rede fora do ar');
    return {
      ok: true,
      status: 200,
      body: {
        getReader() {
          return {
            async read() {
              if (indice < pedacos.length) {
                const valor = pedacos[indice];
                indice += 1;
                return { value: valor, done: false };
              }
              if (travarNoFim) return new Promise(() => {}); // nunca resolve
              return { value: undefined, done: true };
            }
          };
        }
      }
    };
  };
}

function janelaFake({ MediaSource, ManagedMediaSource } = {}) {
  return {
    location: { protocol: 'http:', host: '127.0.0.1:8080' },
    MediaSource,
    ManagedMediaSource,
    fetch: undefined
  };
}

const urlImplFake = () => ({
  createObjectURL: () => 'blob:fake',
  revokeObjectURL: () => {}
});

test('mediaSourceSuportado: sem window nenhuma, não suporta', () => {
  assert.strictEqual(mediaSourceSuportado(undefined), false);
});

test('mediaSourceSuportado: sem MediaSource nem ManagedMediaSource, não suporta', () => {
  assert.strictEqual(mediaSourceSuportado(janelaFake()), false);
});

test('mediaSourceSuportado: isTypeSupported lançando exceção conta como sem suporte', () => {
  class MSQuebrada { static isTypeSupported() { throw new Error('boom'); } }
  assert.strictEqual(mediaSourceSuportado(janelaFake({ MediaSource: MSQuebrada })), false);
});

test('mediaSourceSuportado: MediaSource que aceita o baseline conta como suporte', () => {
  class MSOk { static isTypeSupported() { return true; } }
  assert.strictEqual(mediaSourceSuportado(janelaFake({ MediaSource: MSOk })), true);
});

test('start() sem suporte cai para o MJPEG na hora, sem lançar exceção', () => {
  const video = criarVideo();
  const motivos = [];
  const player = new VideoStreamPlayer(video, {
    janela: janelaFake(), // sem MediaSource
    onFallback: (m) => motivos.push(m)
  });
  assert.doesNotThrow(() => player.start());
  assert.strictEqual(motivos.length, 1);
  assert.strictEqual(video.classes.has('active'), false);
});

test('caminho feliz: quadros chegando aparecem no SourceBuffer e o <video> fica visível', async () => {
  const video = criarVideo();
  const sourceBuffer = fakeSourceBuffer();
  const MSClasse = fakeMediaSourceClasse(sourceBuffer);
  class MSComSuporte extends MSClasse { static isTypeSupported() { return true; } }
  const janela = janelaFake({ MediaSource: MSComSuporte });

  const pedaco1 = new Uint8Array([1, 2, 3]);
  const pedaco2 = new Uint8Array([4, 5, 6]);
  const estados = [];
  const player = new VideoStreamPlayer(video, {
    janela,
    fetchImpl: fetchComPedacos([pedaco1, pedaco2]),
    urlImpl: urlImplFake(),
    onEstado: (e) => estados.push(e)
  });

  player.start();
  // `sourceopen` é quem dispara a busca de verdade (ver `iniciarMediaSource`/`aoAbrirFonte`).
  MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));

  assert.deepStrictEqual(sourceBuffer.anexados, [pedaco1, pedaco2]);
  assert.strictEqual(video.classes.has('active'), true);
  assert.strictEqual(estados.includes('ao-vivo'), true);
});

test('pedaço chegando com o SourceBuffer ocupado (updating) fica na fila e sai no updateend', async () => {
  const video = criarVideo();
  const sourceBuffer = fakeSourceBuffer();
  const MSClasse = fakeMediaSourceClasse(sourceBuffer);
  class MSComSuporte extends MSClasse { static isTypeSupported() { return true; } }
  const janela = janelaFake({ MediaSource: MSComSuporte });

  const pedaco1 = new Uint8Array([1]);
  const pedaco2 = new Uint8Array([2]);
  const player = new VideoStreamPlayer(video, {
    janela,
    // `travarNoFim`: sem isto, o `read()` seguinte devolve `done: true` assim que os dois
    // pedaços acabam — o player trata isso como queda de conexão e zera a fila de pedaços
    // ainda não anexados (corretamente: uma reconexão de verdade cria outro SourceBuffer, e
    // bytes soltos sem o init segment na frente não servem para ele). Este teste quer isolar
    // só o comportamento de fila/`updating`, sem uma queda de conexão no meio atrapalhando.
    fetchImpl: fetchComPedacos([pedaco1, pedaco2], { travarNoFim: true }),
    urlImpl: urlImplFake()
  });

  // Ocupa o SourceBuffer antes de a leitura começar a entregar pedaços: os dois têm que
  // esperar na fila e só sair quando `updateend` disparar.
  sourceBuffer.updating = true;

  player.start();
  MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));

  assert.deepStrictEqual(sourceBuffer.anexados, [], 'nada sai enquanto updating é true');

  sourceBuffer.updating = false;
  sourceBuffer.dispatch('updateend');
  assert.deepStrictEqual(sourceBuffer.anexados, [pedaco1]);

  sourceBuffer.dispatch('updateend');
  assert.deepStrictEqual(sourceBuffer.anexados, [pedaco1, pedaco2]);
});

test('appendBuffer falhando é tratado como queda de conexão (tenta de novo, não desiste na hora)', () => {
  const video = criarVideo();
  const sourceBuffer = fakeSourceBuffer();
  sourceBuffer.appendBuffer = () => { throw new Error('dado corrompido'); };
  const MSClasse = fakeMediaSourceClasse(sourceBuffer);
  class MSComSuporte extends MSClasse { static isTypeSupported() { return true; } }
  const janela = janelaFake({ MediaSource: MSComSuporte });

  const estados = [];
  const motivos = [];
  const player = new VideoStreamPlayer(video, {
    janela,
    fetchImpl: fetchComPedacos([new Uint8Array([1])]),
    urlImpl: urlImplFake(),
    onEstado: (e) => estados.push(e),
    onFallback: (m) => motivos.push(m)
  });

  player.start();
  MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  // Empurra um pedaço direto na fila e manda escoar: é o mesmo caminho que `bombearLeitura`
  // percorre ao receber um pedaço de verdade, sem depender do timing do `fetch` fake.
  player.filaDePedacos.push(new Uint8Array([9]));
  player.escoarFila();

  assert.strictEqual(estados.includes('reconectando'), true);
  assert.strictEqual(motivos.length, 0, 'uma falha só não desiste — tenta de novo primeiro');
});

test('depois de várias quedas seguidas, desiste e cai para o MJPEG', () => {
  const video = criarVideo();
  const sourceBuffer = fakeSourceBuffer();
  const MSClasse = fakeMediaSourceClasse(sourceBuffer);
  class MSComSuporte extends MSClasse { static isTypeSupported() { return true; } }
  const janela = janelaFake({ MediaSource: MSComSuporte });

  const motivos = [];
  const player = new VideoStreamPlayer(video, {
    janela,
    fetchImpl: fetchComPedacos([]),
    urlImpl: urlImplFake(),
    onFallback: (m) => motivos.push(m)
  });
  player.querTransmitir = true; // simula start() já em andamento, sem depender do fetch real

  for (let i = 0; i < 10; i += 1) {
    player.aoQuedaDeConexao(`queda de teste ${i}`);
  }

  assert.strictEqual(motivos.length, 1, 'só desiste (e avisa) uma vez, não a cada tentativa');
  assert.strictEqual(video.classes.has('active'), false);
});

test('stop() encerra sem chamar onFallback e esconde o vídeo', () => {
  const video = criarVideo();
  video.classList.add('active');
  const sourceBuffer = fakeSourceBuffer();
  const MSClasse = fakeMediaSourceClasse(sourceBuffer);
  class MSComSuporte extends MSClasse { static isTypeSupported() { return true; } }
  const janela = janelaFake({ MediaSource: MSComSuporte });

  const motivos = [];
  const player = new VideoStreamPlayer(video, {
    janela,
    fetchImpl: fetchComPedacos([]),
    urlImpl: urlImplFake(),
    onFallback: (m) => motivos.push(m)
  });

  player.start();
  MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  player.stop();

  assert.strictEqual(motivos.length, 0);
  assert.strictEqual(video.classes.has('active'), false);
});
