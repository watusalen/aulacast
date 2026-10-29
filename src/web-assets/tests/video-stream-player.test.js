import test from 'node:test';
import assert from 'node:assert';
import { VideoStreamPlayer, mediaSourceSuportado, codecDoInitSegment } from '../js/video-stream-player.js';

/** blob: -> MediaSource, para o `removeAttribute('src')` do vídeo fake achar a fonte. */
const blobs = new Map();

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
    currentTime: 0,
    paused: true,
    playChamadas: 0,
    play() { this.playChamadas += 1; this.paused = false; return Promise.resolve(); },
    addEventListener(evt, fn) { (listeners[evt] ||= []).push(fn); },
    dispatch(evt, dados) { (listeners[evt] || []).forEach((fn) => fn(dados)); },
    getAttribute(nome) { return attrs[nome] ?? null; },
    setAttribute(nome, valor) { attrs[nome] = valor; },
    // Como no navegador, tirar o `src` fecha a MediaSource que estava ligada a ele.
    removeAttribute(nome) {
      if (nome === 'src' && attrs.src) blobs.get(attrs.src)?.fecharPorRemocaoDoSrc();
      delete attrs[nome];
    },
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
    removidos: [],
    /** Faixas bufferizadas: [[inicio, fim], ...]. */
    faixas: [],
    get buffered() {
      const f = this.faixas;
      return { length: f.length, start: (i) => f[i][0], end: (i) => f[i][1] };
    },
    remove(a, b) { this.removidos.push([a, b]); },
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
    // Como no navegador: o evento chega DEPOIS, quando quem encerrou já seguiu em frente.
    endOfStream() {
      this.readyState = 'ended';
      setImmediate(() => this.dispatch('sourceended'));
    }
    fecharPorRemocaoDoSrc() {
      this.readyState = 'closed';
      setImmediate(() => this.dispatch('sourceclose'));
    }
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
  const docListeners = {};
  return {
    document: {
      visibilityState: 'visible',
      docListeners,
      addEventListener(evt, fn) { (docListeners[evt] ||= []).push(fn); }
    },
    location: { protocol: 'http:', host: '127.0.0.1:8080' },
    MediaSource,
    ManagedMediaSource,
    fetch: undefined
  };
}

let contadorBlob = 0;
const urlImplFake = () => ({
  createObjectURL: (ms) => {
    contadorBlob += 1;
    blobs.set(`blob:fake${contadorBlob}`, ms);
    return `blob:fake${contadorBlob}`;
  },
  revokeObjectURL: () => {}
});

/** Init segment mínimo com uma caixa `avcC` (versão 1, profile/compat/level dados). */
function initSegment(profile = 0x42, compat = 0xe0, level = 0x1e) {
  return new Uint8Array([0, 0, 0, 8, 0x6d, 0x6f, 0x6f, 0x76, 0x61, 0x76, 0x63, 0x43, 1, profile, compat, level, 0xff]);
}

const aguardar = () => new Promise((r) => setImmediate(r));

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

  const pedaco1 = initSegment();
  const pedaco2 = new Uint8Array([4, 5, 6]);
  const estados = [];
  const player = new VideoStreamPlayer(video, {
    janela,
    fetchImpl: fetchComPedacos([pedaco1, pedaco2], { travarNoFim: true }),
    urlImpl: urlImplFake(),
    onEstado: (e) => estados.push(e)
  });

  player.start();
  // `sourceopen` é quem dispara a busca de verdade (ver `iniciarMediaSource`/`aoAbrirFonte`).
  MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));

  assert.deepStrictEqual(sourceBuffer.anexados, [pedaco1, pedaco2]);
  // O append, sozinho, não mostra o <video>: só o evento `playing` (item 5).
  assert.strictEqual(video.classes.has('active'), false);
  assert.strictEqual(estados.includes('ao-vivo'), false);

  video.dispatch('playing');
  assert.strictEqual(video.classes.has('active'), true);
  assert.strictEqual(estados.includes('ao-vivo'), true);
  player.stop();
});

test('pedaço chegando com o SourceBuffer ocupado (updating) fica na fila e sai no updateend', async () => {
  const video = criarVideo();
  const sourceBuffer = fakeSourceBuffer();
  const MSClasse = fakeMediaSourceClasse(sourceBuffer);
  class MSComSuporte extends MSClasse { static isTypeSupported() { return true; } }
  const janela = janelaFake({ MediaSource: MSComSuporte });

  const pedaco1 = initSegment();
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

test('appendBuffer falhando é tratado como queda de conexão (tenta de novo, não desiste na hora)', async () => {
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
    fetchImpl: fetchComPedacos([initSegment()], { travarNoFim: true }),
    urlImpl: urlImplFake(),
    onEstado: (e) => estados.push(e),
    onFallback: (m) => motivos.push(m)
  });

  player.start();
  MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  await aguardar();
  await aguardar();

  assert.strictEqual(estados.includes('reconectando'), true);
  assert.strictEqual(motivos.length, 0, 'uma falha só não desiste — tenta de novo primeiro');
  player.stop();
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

// ---------------------------------------------------------------------------------------
// Correções da revisão crítica (itens 1 a 8). Dublês despacham eventos de verdade.
// ---------------------------------------------------------------------------------------

/** Monta player + dublês; `pedacos` é o que o servidor entrega em /stream.mp4. */
function montar({ pedacos = [initSegment()], travarNoFim = true, opcoes = {} } = {}) {
  const video = criarVideo();
  const sb = fakeSourceBuffer();
  const MSClasse = fakeMediaSourceClasse(sb);
  class MSComSuporte extends MSClasse {
    static isTypeSupported(t) { MSComSuporte.tipos.push(t); return MSComSuporte.aceita(t); }
  }
  MSComSuporte.tipos = [];
  MSComSuporte.aceita = () => true;
  const janela = janelaFake({ MediaSource: MSComSuporte });
  const estados = [];
  const motivos = [];
  const tiposDoSB = [];
  const original = MSClasse.prototype.addSourceBuffer;
  MSClasse.prototype.addSourceBuffer = function (tipo) { tiposDoSB.push(tipo); return original.call(this, tipo); };
  const player = new VideoStreamPlayer(video, {
    janela,
    fetchImpl: fetchComPedacos(pedacos, { travarNoFim }),
    urlImpl: urlImplFake(),
    onEstado: (e) => estados.push(e),
    onFallback: (m) => motivos.push(m),
    ...opcoes
  });
  return { video, sb, MSClasse, MSComSuporte, janela, player, estados, motivos, tiposDoSB };
}

async function iniciarComDados(ctx) {
  ctx.player.start();
  ctx.MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  await aguardar();
  await aguardar();
}

const quota = () => { const e = new Error('cheio'); e.name = 'QuotaExceededError'; return e; };

test('item 1: late joiner (tfdt ~1800 s) é levado para a borda ao vivo e recebe play()', async () => {
  const ctx = montar({ pedacos: [initSegment(), new Uint8Array([9])] });
  await iniciarComDados(ctx);
  assert.strictEqual(ctx.video.playChamadas, 0, 'sem mídia bufferizada ainda, nada de play');

  ctx.sb.faixas = [[1800, 1801.2]];
  ctx.sb.dispatch('updateend');

  assert.ok(Math.abs(ctx.video.currentTime - 1801.1) < 1e-9, `currentTime=${ctx.video.currentTime}`);
  assert.strictEqual(ctx.video.playChamadas, 1);
  ctx.player.stop();
});

test('item 1: video fica muted + playsinline para o autoplay funcionar', () => {
  const ctx = montar();
  assert.strictEqual(ctx.video.muted, true);
  assert.strictEqual(ctx.video.playsInline, true);
});

test('item 2: atraso acima de 2 s pula para buffered.end - 0,1 (timer, waiting, timeupdate)', async () => {
  for (const origem of ['verificar', 'waiting', 'timeupdate']) {
    const ctx = montar();
    await iniciarComDados(ctx);
    ctx.sb.faixas = [[100, 110]];
    ctx.video.currentTime = 105;
    if (origem === 'verificar') ctx.player.verificar();
    else ctx.video.dispatch(origem);
    assert.ok(Math.abs(ctx.video.currentTime - 109.9) < 1e-9, `${origem}: ${ctx.video.currentTime}`);
    ctx.player.stop();
  }
});

test('item 2: atraso pequeno (< 2 s) não pula', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[100, 110]];
  ctx.video.currentTime = 109.4;
  ctx.player.verificar();
  assert.strictEqual(ctx.video.currentTime, 109.4);
  ctx.player.stop();
});

test('item 2: currentTime dentro de um buraco pula para o início da próxima faixa', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[100, 102], [108, 109]];
  ctx.video.currentTime = 103;
  ctx.video.dispatch('stalled');
  assert.strictEqual(ctx.video.currentTime, 108);
  ctx.player.stop();
});

test('item 2: aba voltando a ficar visível pula para o ao vivo', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[100, 130]];
  ctx.video.currentTime = 105;
  ctx.janela.document.docListeners.visibilitychange.forEach((fn) => fn());
  assert.ok(Math.abs(ctx.video.currentTime - 129.9) < 1e-9);
  ctx.player.stop();
});

test('tela parada (relógio sem avançar por muito tempo) NÃO é queda nem reconecta', async () => {
  let agora = 0;
  const ctx = montar({ opcoes: { agora: () => agora } });
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[100, 100.5]];
  ctx.video.currentTime = 100.4;
  for (const t of [0, 1000, 3000, 8000, 60000]) { agora = t; ctx.player.verificar(); }
  assert.strictEqual(ctx.player.tentativas, 0);
  assert.ok(!ctx.estados.includes('reconectando'));
  ctx.player.stop();
});

test('item 7: atraso entre 0,3 s e 2 s acelera (sem seek) e volta a 1x ao alcançar', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[100, 110]];
  ctx.video.currentTime = 108.5; // atraso 1,5 s
  ctx.player.verificar();
  assert.strictEqual(ctx.video.currentTime, 108.5, 'não pula');
  assert.ok(ctx.video.playbackRate > 1 && ctx.video.playbackRate <= 1.1);
  ctx.video.currentTime = 109.95; // atraso 0,05 s
  ctx.player.verificar();
  assert.strictEqual(ctx.video.playbackRate, 1);
  ctx.player.stop();
});

test('item 7: atraso acima de 2 s pula e deixa a velocidade em 1x', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[100, 110]];
  ctx.video.currentTime = 107;
  ctx.player.verificar();
  assert.ok(Math.abs(ctx.video.currentTime - 109.9) < 1e-9);
  assert.strictEqual(ctx.video.playbackRate, 1);
  ctx.player.stop();
});

test('item 6: quota com TUDO à frente do currentTime (aba oculta) libera, salta ao vivo e não conta queda', async () => {
  const ctx = montar();
  let falhasRestantes = 1;
  const original = ctx.sb.appendBuffer.bind(ctx.sb);
  ctx.sb.appendBuffer = (p) => {
    if (falhasRestantes > 0) { falhasRestantes -= 1; throw quota(); }
    original(p);
  };
  ctx.sb.faixas = [[100, 130]];
  ctx.video.currentTime = 100; // nada atrás do relógio
  await iniciarComDados(ctx);
  assert.strictEqual(ctx.player.tentativas, 0, 'quota não é queda');
  assert.deepStrictEqual(ctx.sb.removidos, [[100, 129.5]]);
  assert.ok(Math.abs(ctx.video.currentTime - 129.9) < 1e-9, `currentTime=${ctx.video.currentTime}`);
  ctx.sb.faixas = [[129.5, 130]];
  ctx.sb.dispatch('updateend');
  assert.strictEqual(ctx.sb.anexados.length, 1);
  assert.strictEqual(ctx.player.tentativas, 0);
  ctx.player.stop();
});

test('item 3: updateend apara o buffer mais velho que ~10 s atrás do currentTime', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[100, 130]];
  ctx.video.currentTime = 129.9;
  ctx.sb.dispatch('updateend');
  assert.strictEqual(ctx.sb.removidos.length, 1);
  assert.strictEqual(ctx.sb.removidos[0][0], 0);
  assert.ok(Math.abs(ctx.sb.removidos[0][1] - 119.9) < 1e-9);
  ctx.player.stop();
});

test('item 3: buffer recente não é aparado', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.sb.faixas = [[125, 130]];
  ctx.video.currentTime = 129.9;
  ctx.sb.dispatch('updateend');
  assert.deepStrictEqual(ctx.sb.removidos, []);
  ctx.player.stop();
});

test('item 3: QuotaExceededError apara e tenta de novo uma vez, sem contar queda', async () => {
  const ctx = montar();
  let falhasRestantes = 1;
  const original = ctx.sb.appendBuffer.bind(ctx.sb);
  ctx.sb.appendBuffer = (p) => {
    if (falhasRestantes > 0) { falhasRestantes -= 1; throw quota(); }
    original(p);
  };
  ctx.sb.faixas = [[100, 130]];
  ctx.video.currentTime = 125;
  await iniciarComDados(ctx);

  assert.strictEqual(ctx.player.tentativas, 0, 'quota não é queda');
  assert.deepStrictEqual(ctx.sb.removidos, [[0, 124]], 'apara tudo antes de currentTime - 1');
  assert.strictEqual(ctx.sb.anexados.length, 0, 'ainda esperando o updateend do remove');

  ctx.sb.faixas = [[124, 130]]; // o remove já aconteceu
  ctx.sb.dispatch('updateend'); // o retry anexa o pedaço guardado
  assert.strictEqual(ctx.sb.anexados.length, 1);
  assert.strictEqual(ctx.player.tentativas, 0);
  assert.strictEqual(ctx.motivos.length, 0);
  ctx.player.stop();
});

test('item 3: quota de novo no retry aí sim é queda', async () => {
  const ctx = montar();
  ctx.sb.appendBuffer = () => { throw quota(); };
  ctx.sb.faixas = [[100, 130]];
  ctx.video.currentTime = 125;
  await iniciarComDados(ctx);
  assert.strictEqual(ctx.player.tentativas, 0);
  ctx.sb.faixas = [[124, 130]];
  ctx.sb.dispatch('updateend');
  assert.strictEqual(ctx.player.tentativas, 1);
  ctx.player.stop();
});

test('item 4: uma queda conta UMA tentativa (eventos da MediaSource antiga são ignorados)', async () => {
  // Servidor fecha a conexão logo depois do init: uma queda real.
  const ctx = montar({ travarNoFim: false });
  await iniciarComDados(ctx);
  await aguardar(); // dá tempo de sourceended/sourceclose da fonte antiga chegarem
  await aguardar();
  assert.strictEqual(ctx.player.tentativas, 1);
  assert.deepStrictEqual(ctx.estados, ['reconectando']);
  ctx.player.stop();
});

test('item 4: o fake despacha sourceended (endOfStream) e sourceclose (src removido)', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  const antiga = ctx.MSClasse.instanciaMaisRecente;
  const vistos = [];
  antiga.addEventListener('sourceended', () => vistos.push('sourceended'));
  antiga.addEventListener('sourceclose', () => vistos.push('sourceclose'));
  ctx.player.stop();
  await aguardar();
  assert.deepStrictEqual(vistos.sort(), ['sourceclose', 'sourceended']);
  assert.strictEqual(ctx.player.tentativas, 0, 'stop de propósito não vira queda');
});

test('item 5: <video> só aparece em `playing`, não no append do init segment', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  assert.strictEqual(ctx.video.classes.has('active'), false);
  assert.deepStrictEqual(ctx.estados, []);
  ctx.video.dispatch('playing');
  assert.strictEqual(ctx.video.classes.has('active'), true);
  assert.deepStrictEqual(ctx.estados, ['ao-vivo']);
  ctx.player.stop();
});

test('item 5: entrar durante a pausa (só init, nenhuma mídia) nunca mostra o <video>', async () => {
  const ctx = montar();
  ctx.player.definirPausado(true);
  await iniciarComDados(ctx);
  ctx.player.verificar();
  assert.strictEqual(ctx.video.classes.has('active'), false);
  assert.deepStrictEqual(ctx.estados, []);
  ctx.player.stop();
});

test('item 6: codecDoInitSegment lê profile/compat/level do avcC', () => {
  assert.strictEqual(codecDoInitSegment(initSegment(0x64, 0x00, 0x28)), 'avc1.640028');
  assert.strictEqual(codecDoInitSegment(initSegment(0x42, 0xe0, 0x1e)), 'avc1.42E01E');
  assert.strictEqual(codecDoInitSegment(new Uint8Array([1, 2, 3])), null);
});

test('item 6: addSourceBuffer e isTypeSupported usam o codec do init segment', async () => {
  const ctx = montar({ pedacos: [initSegment(0x4d, 0x40, 0x1f)] });
  await iniciarComDados(ctx);
  assert.deepStrictEqual(ctx.tiposDoSB, ['video/mp4; codecs="avc1.4D401F"']);
  assert.ok(ctx.MSComSuporte.tipos.includes('video/mp4; codecs="avc1.4D401F"'));
  ctx.player.stop();
});

test('item 6: init segment partido em dois pedaços ainda acha o codec e anexa inteiro', async () => {
  const inteiro = initSegment(0x64, 0, 0x28);
  const ctx = montar({ pedacos: [inteiro.slice(0, 10), inteiro.slice(10)] });
  await iniciarComDados(ctx);
  assert.deepStrictEqual(ctx.tiposDoSB, ['video/mp4; codecs="avc1.640028"']);
  assert.deepStrictEqual(ctx.sb.anexados.map((p) => p.length), [inteiro.length]);
  ctx.player.stop();
});

test('item 6: sem avcC legível (chegou moof) usa avc1.42E01E', async () => {
  const moof = new Uint8Array([0, 0, 0, 8, 0x6d, 0x6f, 0x6f, 0x66]);
  const ctx = montar({ pedacos: [moof] });
  await iniciarComDados(ctx);
  assert.deepStrictEqual(ctx.tiposDoSB, ['video/mp4; codecs="avc1.42E01E"']);
  ctx.player.stop();
});

test('item 6: codec derivado não suportado cai para o MJPEG', async () => {
  const ctx = montar({ pedacos: [initSegment(0x64, 0, 0x33)] });
  ctx.MSComSuporte.aceita = (t) => t.includes('42E01E');
  await iniciarComDados(ctx);
  assert.strictEqual(ctx.motivos.length, 1);
});

test('item 7: depois do fallback, start() não tenta H.264 de novo nem avisa de novo', () => {
  const ctx = montar();
  ctx.player.start();
  ctx.player.cairParaFallback('teste');
  assert.strictEqual(ctx.motivos.length, 1);
  ctx.player.start();
  assert.strictEqual(ctx.player.querTransmitir, false);
  assert.strictEqual(ctx.motivos.length, 1);
});

test('item 8: HTTP 200 seguido de queda sem nunca tocar continua somando até o fallback', async () => {
  const ctx = montar({ travarNoFim: false });
  ctx.player.start();
  for (let i = 0; i < 6 && ctx.player.querTransmitir; i += 1) {
    ctx.MSClasse.instanciaMaisRecente.dispatch('sourceopen');
    await aguardar();
    await aguardar();
    ctx.player.limparTimer();
    ctx.player.conectar();
  }
  assert.strictEqual(ctx.motivos.length, 1);
  assert.strictEqual(ctx.player.querTransmitir, false);
});

test('item 8: reprodução de verdade (`playing`) zera as tentativas', async () => {
  const ctx = montar();
  await iniciarComDados(ctx);
  ctx.player.tentativas = 3;
  ctx.video.dispatch('playing');
  assert.strictEqual(ctx.player.tentativas, 0);
  ctx.player.stop();
});

test('item 8: fetch abortado de uma tentativa já trocada não conta como queda', async () => {
  const video = criarVideo();
  const sb = fakeSourceBuffer();
  const MSClasse = fakeMediaSourceClasse(sb);
  class MS extends MSClasse { static isTypeSupported() { return true; } }
  const rejeitar = [];
  const player = new VideoStreamPlayer(video, {
    janela: janelaFake({ MediaSource: MS }),
    fetchImpl: () => new Promise((_, rej) => rejeitar.push(rej)),
    urlImpl: urlImplFake()
  });
  player.start();
  MSClasse.instanciaMaisRecente.dispatch('sourceopen'); // tentativa 1 pendurada no fetch
  player.conectar(); // troca por uma segunda
  MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  rejeitar[0](new Error('AbortError'));
  await aguardar();
  assert.strictEqual(player.tentativas, 0);
  player.stop();
});

// ---------------------------------------------------------------------------------------
// Volta ao H.264 depois do fallback (prova curta): ver `tentarDeNovo()`.
// ---------------------------------------------------------------------------------------

/** Cai para o MJPEG e deixa os relógios sob controle do teste. */
function emFallbackComRelogio(t, opcoes = {}) {
  const recuperou = [];
  const ctx = montar({ opcoes: { onRecuperou: () => recuperou.push(1), ...opcoes } });
  ctx.player.start();
  ctx.player.cairParaFallback('queda de teste');
  t.mock.timers.enable({ apis: ['setTimeout'] });
  return { ...ctx, recuperou };
}

async function abrirProva(ctx) {
  assert.strictEqual(ctx.player.tentarDeNovo(), true);
  ctx.MSClasse.instanciaMaisRecente.dispatch('sourceopen');
  await aguardar();
  await aguardar();
}

test('prova: sem ter caído antes, não há o que tentar', () => {
  const ctx = montar();
  assert.strictEqual(ctx.player.tentarDeNovo(), false);
});

test('prova: navegador sem MediaSource não tenta de novo (semSuporte)', () => {
  const janela = janelaFake({});
  const player = new VideoStreamPlayer(criarVideo(), { janela, fetchImpl: fetchComPedacos([]), urlImpl: urlImplFake() });
  player.start();
  assert.strictEqual(player.semSuporte, true);
  assert.strictEqual(player.tentarDeNovo(), false);
});

test('prova: tocando estável por 5 s chama onRecuperou', async (t) => {
  const ctx = emFallbackComRelogio(t);
  await abrirProva(ctx);
  ctx.video.dispatch('playing');
  assert.strictEqual(ctx.recuperou.length, 0, 'ainda não: precisa ficar estável');
  t.mock.timers.tick(5_000);
  assert.strictEqual(ctx.recuperou.length, 1);
  assert.strictEqual(ctx.player.emProva, false);
  ctx.player.stop();
});

test('prova: queda durante a prova volta ao MJPEG na hora e avisa onFallback de novo', async (t) => {
  const ctx = emFallbackComRelogio(t);
  assert.strictEqual(ctx.motivos.length, 1);
  await abrirProva(ctx);
  ctx.player.aoQuedaDeConexao('rede caiu');
  assert.strictEqual(ctx.motivos.length, 2);
  assert.match(ctx.motivos[1], /prova/);
  assert.strictEqual(ctx.recuperou.length, 0);
  assert.strictEqual(ctx.player.emProva, false);
});

test('prova: cair depois de tocar, antes dos 5 s, cancela a recuperação', async (t) => {
  const ctx = emFallbackComRelogio(t);
  await abrirProva(ctx);
  ctx.video.dispatch('playing');
  ctx.player.aoQuedaDeConexao('rede caiu');
  t.mock.timers.tick(10_000);
  assert.strictEqual(ctx.recuperou.length, 0);
  assert.strictEqual(ctx.motivos.length, 2);
});

test('prova: 15 s sem tocar desiste e avisa onFallback de novo', async (t) => {
  const ctx = emFallbackComRelogio(t);
  await abrirProva(ctx);
  t.mock.timers.tick(14_000);
  assert.strictEqual(ctx.motivos.length, 1, 'ainda dentro do prazo');
  t.mock.timers.tick(1_000);
  assert.strictEqual(ctx.motivos.length, 2);
  assert.strictEqual(ctx.recuperou.length, 0);
});

test('prova: stop() no meio devolve o player ao estado de fallback e permite tentar depois', async (t) => {
  const ctx = emFallbackComRelogio(t);
  await abrirProva(ctx);
  ctx.player.stop();
  assert.strictEqual(ctx.player.emProva, false);
  t.mock.timers.tick(30_000);
  assert.strictEqual(ctx.recuperou.length, 0, 'os relógios da prova foram limpos');
  assert.strictEqual(ctx.player.tentarDeNovo(), true, 'continua apto a nova prova');
  ctx.player.stop();
});
