import test from 'node:test';
import assert from 'node:assert';
import { ManterTelaAcesa } from '../js/manter-tela-acesa.js';

/** Alvo de eventos mínimo, com contagem de ouvintes para conferir a limpeza. */
function alvoDeEventos() {
  const ouvintes = {};
  return {
    ouvintes,
    addEventListener(evt, fn) { (ouvintes[evt] ||= new Set()).add(fn); },
    removeEventListener(evt, fn) { ouvintes[evt]?.delete(fn); },
    dispatch(evt) { [...(ouvintes[evt] || [])].forEach((fn) => fn({ type: evt })); },
    quantos(evt) { return ouvintes[evt]?.size || 0; }
  };
}

/** <video> dublê: `play()` devolve a promessa que o teste escolher. */
function fakeVideo(resultadoDoPlay) {
  const v = {
    ...alvoDeEventos(),
    tag: 'video',
    attrs: {},
    style: {},
    filhos: [],
    paused: true,
    loop: false,
    muted: false,
    volume: 1,
    duration: NaN,
    currentTime: 0,
    plays: 0,
    removido: false,
    setAttribute(n, val) { this.attrs[n] = val; },
    appendChild(f) { this.filhos.push(f); },
    play() {
      this.plays += 1;
      const r = resultadoDoPlay();
      if (r === 'ok') { this.paused = false; return Promise.resolve(); }
      return Promise.reject(Object.assign(new Error('sem gesto'), { name: 'NotAllowedError' }));
    },
    pause() { this.paused = true; },
    remove() { this.removido = true; }
  };
  return v;
}

function ambiente({ seguro = false, wakeLock = null, play = () => 'ok' } = {}) {
  const documento = alvoDeEventos();
  documento.visibilityState = 'visible';
  documento.videos = [];
  documento.body = { filhos: [], appendChild(el) { this.filhos.push(el); } };
  documento.createElement = (tag) => {
    if (tag === 'video') { const v = fakeVideo(play); documento.videos.push(v); return v; }
    return { tag, src: '', type: '' };
  };
  const navigator = {};
  if (wakeLock) navigator.wakeLock = wakeLock;
  const janela = { isSecureContext: seguro, navigator };
  return { janela, documento };
}

/** navigator.wakeLock dublê que registra os pedidos e as sentinelas. */
function fakeWakeLock({ recusar = false } = {}) {
  const sentinelas = [];
  return {
    sentinelas,
    pedidos: 0,
    request(tipo) {
      assert.strictEqual(tipo, 'screen');
      this.pedidos += 1;
      if (recusar) return Promise.reject(new Error('recusado'));
      const s = {
        ...alvoDeEventos(),
        released: false,
        release() { this.released = true; this.dispatch('release'); return Promise.resolve(); }
      };
      sentinelas.push(s);
      return Promise.resolve(s);
    }
  };
}

const tique = () => new Promise((r) => setTimeout(r, 0));

test('http:// na rede local (sem contexto seguro): usa o video, com som e no DOM', async () => {
  const { janela, documento } = ambiente();
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.ativar();
  await tique();

  assert.strictEqual(documento.videos.length, 1);
  const [video] = documento.videos;
  assert.strictEqual(video.plays, 1, 'play() chamado dentro do gesto, sem esperar nada');
  assert.ok(documento.body.filhos.includes(video), 'o WebKit ignora video fora do DOM');
  assert.notStrictEqual(video.style.display, 'none', 'nem com display: none');
  // Mudo nao segura a tela (medido no Chrome 153 e no WebKit).
  assert.strictEqual(video.muted, false);
  assert.strictEqual(video.volume, 1);
  assert.ok('playsinline' in video.attrs, 'sem playsinline o iPhone abre em tela cheia');
  // mp4 primeiro: no WebKit o laco do webm solta a trava a cada volta.
  assert.deepStrictEqual(video.filhos.map((f) => f.type), ['video/mp4', 'video/webm']);
  assert.match(video.filhos[0].src, /^data:video\/mp4;base64,/);
  assert.match(video.filhos[1].src, /^data:video\/webm;base64,/);
});

test('mesmo com navigator.wakeLock, sem contexto seguro vai de video', () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: false, wakeLock: wl });
  new ManterTelaAcesa({ janela, documento }).ativar();

  assert.strictEqual(wl.pedidos, 0);
  assert.strictEqual(documento.videos.length, 1);
});

test('contexto seguro com wakeLock: usa a API e nao cria video', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.ativar();
  await tique();

  assert.strictEqual(wl.pedidos, 1);
  assert.strictEqual(documento.videos.length, 0);
  assert.strictEqual(tela.sentinela, wl.sentinelas[0]);
});

test('wakeLock: repede a trava ao voltar para a pagina', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  await tique();

  // O sistema solta a trava quando a aba some.
  documento.visibilityState = 'hidden';
  wl.sentinelas[0].release();
  documento.dispatch('visibilitychange');
  await tique();
  assert.strictEqual(wl.pedidos, 1, 'escondida, nao adianta pedir');

  documento.visibilityState = 'visible';
  documento.dispatch('visibilitychange');
  await tique();
  assert.strictEqual(wl.pedidos, 2);
  assert.strictEqual(tela.sentinela, wl.sentinelas[1]);

  // Voltar de novo com a trava de pe nao pede outra.
  documento.dispatch('visibilitychange');
  await tique();
  assert.strictEqual(wl.pedidos, 2);
});

test('wakeLock recusado: cai para o video', async () => {
  const wl = fakeWakeLock({ recusar: true });
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  new ManterTelaAcesa({ janela, documento }).ativar();
  await tique();

  assert.strictEqual(documento.videos.length, 1);
  assert.strictEqual(documento.videos[0].plays, 1);
});

test('ativar() e idempotente', async () => {
  const { janela, documento } = ambiente();
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.ativar();
  tela.ativar();
  tela.ativar();
  await tique();

  assert.strictEqual(documento.videos.length, 1);
  assert.strictEqual(documento.videos[0].plays, 1);
  assert.strictEqual(documento.quantos('visibilitychange'), 1);

  const wl = fakeWakeLock();
  const seguro = ambiente({ seguro: true, wakeLock: wl });
  const tela2 = new ManterTelaAcesa(seguro);
  tela2.ativar();
  tela2.ativar();
  await tique();
  assert.strictEqual(wl.pedidos, 1);
});

test('desativar() para o video, solta a trava e limpa os ouvintes', async () => {
  const { janela, documento } = ambiente();
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  await tique();
  const [video] = documento.videos;

  tela.desativar();
  assert.strictEqual(video.paused, true);
  assert.strictEqual(video.removido, true);
  assert.strictEqual(documento.quantos('visibilitychange'), 0);

  // E pode ativar de novo depois.
  tela.ativar();
  await tique();
  assert.strictEqual(documento.videos.length, 2);

  const wl = fakeWakeLock();
  const seguro = ambiente({ seguro: true, wakeLock: wl });
  const tela2 = new ManterTelaAcesa(seguro);
  tela2.ativar();
  await tique();
  tela2.desativar();
  assert.strictEqual(wl.sentinelas[0].released, true);
});

test('desativar() antes de a trava chegar a solta assim que ela chega', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  tela.desativar();
  await tique();

  assert.strictEqual(wl.sentinelas[0].released, true);
  assert.strictEqual(tela.sentinela, null);
});

test('instalarNoPrimeiroGesto(): ativa no primeiro clique, toque ou tecla, uma vez so', async () => {
  for (const gesto of ['pointerdown', 'keydown', 'touchend']) {
    const { janela, documento } = ambiente();
    const tela = new ManterTelaAcesa({ janela, documento });

    tela.instalarNoPrimeiroGesto();
    tela.instalarNoPrimeiroGesto();
    assert.strictEqual(documento.quantos(gesto), 1, 'instalar duas vezes nao duplica');
    assert.strictEqual(documento.videos.length, 0, 'nada toca antes do gesto');

    documento.dispatch(gesto);
    await tique();
    assert.strictEqual(tela.ativo, true, `${gesto} ativa`);
    assert.strictEqual(documento.videos.length, 1);

    for (const g of ['pointerdown', 'keydown', 'touchend']) {
      assert.strictEqual(documento.quantos(g), 0, `ouvinte de ${g} removido`);
    }
    documento.dispatch('pointerdown');
    await tique();
    assert.strictEqual(documento.videos[0].plays, 1);
  }
});

test('instalarNoPrimeiroGesto() com a tela ja ativa nao faz nada', () => {
  const { janela, documento } = ambiente();
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  tela.instalarNoPrimeiroGesto();
  assert.strictEqual(documento.quantos('pointerdown'), 0);
});

test('ativar() fora de gesto: o video recusado tenta de novo na primeira interacao', async () => {
  let permitido = false;
  const { janela, documento } = ambiente({ play: () => (permitido ? 'ok' : 'recusa') });
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.ativar();
  await tique();
  const [video] = documento.videos;
  assert.strictEqual(video.paused, true);
  assert.strictEqual(documento.quantos('pointerdown'), 1, 'fica esperando um gesto');

  permitido = true;
  documento.dispatch('touchend');
  await tique();
  assert.strictEqual(video.plays, 2);
  assert.strictEqual(video.paused, false);
  assert.strictEqual(documento.videos.length, 1, 'reaproveita o mesmo video');
  assert.strictEqual(documento.quantos('touchend'), 0);
});

test('video pausado pelo sistema volta a tocar quando a pagina reaparece', async () => {
  const { janela, documento } = ambiente();
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  await tique();
  const [video] = documento.videos;

  // O iOS pausa a midia ao bloquear o aparelho.
  documento.visibilityState = 'hidden';
  video.pause();
  documento.dispatch('visibilitychange');
  assert.strictEqual(video.plays, 1, 'escondida, nao tenta');

  documento.visibilityState = 'visible';
  documento.dispatch('visibilitychange');
  await tique();
  assert.strictEqual(video.plays, 2);
  assert.strictEqual(video.paused, false);

  // Ja tocando, voltar para a pagina nao mexe em nada.
  documento.dispatch('visibilitychange');
  assert.strictEqual(video.plays, 2);
});

test('laco do video: webm curto usa loop, mp4 salta para o comeco no timeupdate', () => {
  const { janela, documento } = ambiente();
  new ManterTelaAcesa({ janela, documento }).ativar();
  const [video] = documento.videos;

  video.duration = 0.9;
  video.dispatch('loadedmetadata');
  assert.strictEqual(video.loop, true);

  const { janela: j2, documento: d2 } = ambiente();
  new ManterTelaAcesa({ janela: j2, documento: d2 }).ativar();
  const [mp4] = d2.videos;
  mp4.duration = 6;
  mp4.dispatch('loadedmetadata');
  assert.strictEqual(mp4.loop, false);
  mp4.currentTime = 0.7;
  mp4.dispatch('timeupdate');
  assert.ok(mp4.currentTime < 1, 'voltou para antes do fim');
  mp4.currentTime = 0.3;
  mp4.dispatch('timeupdate');
  assert.strictEqual(mp4.currentTime, 0.3, 'antes de 0,5 s nao mexe');
});
