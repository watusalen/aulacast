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

function ambiente({ seguro = false, wakeLock = null } = {}) {
  const documento = alvoDeEventos();
  documento.visibilityState = 'visible';
  documento.createElement = () => { throw new Error('não deve criar elemento nenhum'); };
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

test('http:// na rede local (sem contexto seguro): não faz nada, nem cria vídeo ou áudio', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: false, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.ativar();
  await tique();

  assert.strictEqual(wl.pedidos, 0, 'sem contexto seguro nem pede a trava');
  assert.strictEqual(tela.sentinela, null);
});

test('contexto seguro com wakeLock: pede a trava da tela', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.ativar();
  await tique();

  assert.strictEqual(wl.pedidos, 1);
  assert.strictEqual(tela.sentinela, wl.sentinelas[0]);
});

test('contexto seguro sem navigator.wakeLock: não quebra', () => {
  const { janela, documento } = ambiente({ seguro: true });
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  assert.strictEqual(tela.sentinela, null);
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

test('wakeLock recusado: segue sem trava e sem erro', async () => {
  const wl = fakeWakeLock({ recusar: true });
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  await tique();

  assert.strictEqual(tela.sentinela, null);
  assert.strictEqual(tela.pedindoWakeLock, false);
});

test('ativar() e idempotente', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.ativar();
  tela.ativar();
  await tique();
  tela.ativar();

  assert.strictEqual(wl.pedidos, 1);
  assert.strictEqual(documento.quantos('visibilitychange'), 1);
});

test('desativar() solta a trava e limpa o ouvinte', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });
  tela.ativar();
  await tique();

  tela.desativar();

  assert.strictEqual(wl.sentinelas[0].released, true);
  assert.strictEqual(tela.sentinela, null);
  assert.strictEqual(documento.quantos('visibilitychange'), 0);
  tela.desativar(); // de novo não quebra
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

test('instalarNoPrimeiroGesto() ativa direto: a Wake Lock não precisa de gesto', async () => {
  const wl = fakeWakeLock();
  const { janela, documento } = ambiente({ seguro: true, wakeLock: wl });
  const tela = new ManterTelaAcesa({ janela, documento });

  tela.instalarNoPrimeiroGesto();
  await tique();

  assert.strictEqual(tela.ativo, true);
  assert.strictEqual(wl.pedidos, 1);
});
