import test from 'node:test';
import assert from 'node:assert';
import { DebugPanel, MAX_LINHAS_LOG, TEXTO_EXPLICATIVO, contarFragmentos } from '../js/debug-panel.js';
import { SocketClient } from '../js/socket-client.js';

function el(tag = 'div') {
  const e = {
    tagName: tag.toUpperCase(), className: '', textContent: '', value: '', hidden: false, style: {},
    filhos: [], listeners: {}, attrs: {}, scrollTop: 0, scrollHeight: 1000, clientHeight: 100,
    get firstChild() { return e.filhos[0] ?? null; },
    appendChild(f) { e.filhos.push(f); return f; },
    removeChild(f) { e.filhos.splice(e.filhos.indexOf(f), 1); },
    addEventListener(n, fn) { (e.listeners[n] ||= []).push(fn); },
    dispatch(n) { (e.listeners[n] || []).forEach((fn) => fn({})); },
    setAttribute(k, v) { e.attrs[k] = v; },
    click() { e.dispatch('click'); }
  };
  return e;
}

function montar({ clipboard, seguro = true, execOk = true } = {}) {
  const body = el('body');
  const docListeners = {};
  const doc = {
    body, visibilityState: 'visible', copiados: [],
    createElement: (t) => el(t),
    createTextNode: (t) => ({ tagName: '#text', textContent: t }),
    addEventListener: (n, fn) => { (docListeners[n] ||= []).push(fn); },
    execCommand: (c) => { doc.copiados.push(c); return execOk; }
  };
  const win = { navigator: clipboard ? { clipboard } : {}, isSecureContext: seguro };
  const timers = [];
  const logs = [];
  const infos = [];
  let t = 0;
  const painel = new DebugPanel({
    doc, win, agora: () => new Date(2026, 0, 1, 10, 0, 0, 7 + t++),
    console: { log: (l) => logs.push(l), info: (l) => infos.push(l) },
    setIntervalImpl: (f, ms) => { const x = { f, ms }; timers.push(x); return x; },
    clearIntervalImpl: (x) => { timers.splice(timers.indexOf(x), 1); }
  });
  return { painel, doc, win, body, timers, logs, infos, docListeners };
}

const achar = (raiz, classe) => {
  if (raiz.className === classe) return raiz;
  for (const f of raiz.filhos ?? []) { const r = achar(f, classe); if (r) return r; }
  return null;
};

test('sem ativar(): nenhum nó, relógio, ouvinte nem global', () => {
  const { painel, body, timers, win, docListeners } = montar();
  assert.strictEqual(body.filhos.length, 0);
  assert.strictEqual(timers.length, 0);
  assert.strictEqual(win.AulaCastDebug, undefined);
  assert.deepStrictEqual(docListeners, {});
  painel.log('x', 'ignorado');
  painel.aoIdentificar();
  assert.strictEqual(painel.linhas.length, 0);
  assert.strictEqual(body.filhos.length, 0);
});

test('ativar(): NÃO cria nenhum elemento na página (sem botão nem gaveta); só global e relógios', () => {
  const { painel, body, timers, win } = montar();
  painel.ativar();
  assert.strictEqual(body.filhos.length, 0, 'nada no DOM: o debug vive só no console');
  assert.strictEqual(achar(body, 'debug-toggle'), null);
  assert.strictEqual(achar(body, 'debug-painel'), null);
  for (const nome of ['log', 'rtt', 'fragmentos', 'texto', 'copiar', 'baixar', 'ajuda']) {
    assert.strictEqual(typeof win.AulaCastDebug[nome], 'function', nome);
  }
  assert.deepStrictEqual(timers.map((t) => t.ms), [2000, 10000]);
  painel.desativar();
  assert.strictEqual(win.AulaCastDebug, undefined);
  assert.strictEqual(timers.length, 0);
  assert.strictEqual(body.filhos.length, 0);
});

test('ao identificar, explica o sistema no console UMA vez e lista os comandos', () => {
  const { painel, infos, body } = montar();
  painel.ativar();
  painel.aoIdentificar();
  painel.aoIdentificar();
  assert.strictEqual(infos.length, 2, 'texto explicativo + comandos, uma vez só');
  for (const t of TEXTO_EXPLICATIVO) assert.ok(infos[0].includes(t));
  assert.ok(TEXTO_EXPLICATIVO.length >= 8 && TEXTO_EXPLICATIVO.length <= 12);
  assert.match(TEXTO_EXPLICATIVO.join(' '), /ScreenCaptureKit[\s\S]*8080[\s\S]*aulacast\.local[\s\S]*30 s[\s\S]*4 conexões/);
  assert.match(infos[1], /AulaCastDebug\.texto\(\)[\s\S]*\.copiar\(\)[\s\S]*\.baixar\(\)/);
  assert.strictEqual(body.filhos.length, 0, 'e continua sem tocar na página');
});

test('registra RTT, resumo min/média/máx, fragmentos e logs no console', () => {
  const { painel, win, timers, logs } = montar();
  painel.ativar();
  win.AulaCastDebug.rtt(4);
  win.AulaCastDebug.rtt(10);
  timers[1].f();
  assert.ok(painel.linhas.some((l) => /PONG rtt 4 ms/.test(l)));
  assert.ok(painel.linhas.some((l) => /RTT em 2 amostra\(s\): min 4 \/ média 7\.0 \/ máx 10 ms/.test(l)));
  assert.match(painel.linhas[1], /^10:00:00\.\d{3} \[ws\]/, 'carimbo com milissegundos');

  // Fragmentos fMP4 sintéticos: moof + trun (flags da amostra 24 bytes depois do tipo); 1 chave.
  const frag = (chave) => {
    const b = new Uint8Array(64);
    b.set([0x6d, 0x6f, 0x6f, 0x66], 0);
    b.set([0x74, 0x72, 0x75, 0x6e], 8);
    b[8 + 24] = chave ? 0x02 : 0x01;
    return b;
  };
  for (let i = 0; i < 30; i += 1) win.AulaCastDebug.fragmentos(frag(i === 0));
  assert.deepStrictEqual(contarFragmentos(frag(true)), { fragmentos: 1, chave: 1 });
  assert.ok(painel.linhas.some((l) => /\+30 fragmentos, 1920 bytes, 1 quadro\(s\)-chave/.test(l)));

  win.AulaCastDebug.log('metricas', 'turma: 3 alunos');
  assert.ok(logs.some((l) => l.includes('turma: 3 alunos')), 'também vai ao console');
});

test('anel de 500 linhas: descarta as mais antigas', () => {
  const { painel } = montar();
  painel.ativar();
  for (let i = 0; i < MAX_LINHAS_LOG + 50; i += 1) painel.log('t', `n${i}`);
  assert.strictEqual(painel.linhas.length, MAX_LINHAS_LOG);
  assert.match(painel.linhas[0], /n50$/);
  assert.match(painel.linhas.at(-1), /n549$/);
});

test('Copiar log: Clipboard API em contexto seguro', async () => {
  const escritos = [];
  const { painel } = montar({ clipboard: { writeText: async (t) => escritos.push(t) } });
  painel.ativar();
  assert.strictEqual(await painel.copiar(), true);
  assert.strictEqual(escritos.length, 1);
  assert.match(escritos[0], /depuração ativada/);
});

test('Copiar log: fallback textarea + execCommand em http (sem contexto seguro)', async () => {
  const { painel, doc, body, infos } = montar({ clipboard: { writeText: async () => { throw new Error('não deveria'); } }, seguro: false });
  painel.ativar();
  await painel.copiar();
  assert.deepStrictEqual(doc.copiados, ['copy']);
  assert.strictEqual(body.filhos.some((f) => f.tagName === 'TEXTAREA'), false, 'textarea removida depois');
  assert.ok(infos.some((l) => /copiado \(modo http\)/.test(l)), 'o resultado sai no console');
});

test('SocketClient: PONG gera RTT e o fechamento registra reconexão, só com o global presente', () => {
  const rtts = [];
  const logs = [];
  globalThis.AulaCastDebug = { log: (c, m) => logs.push(`${c}:${m}`), rtt: (ms) => rtts.push(ms) };
  try {
    const s = new SocketClient(() => {}, () => {});
    s.pingEnviadoEm = Date.now() - 12;
    s.handleMessage({ data: '{"type":"PONG"}' });
    assert.strictEqual(rtts.length, 1);
    assert.ok(rtts[0] >= 12);
    s.handleClose({ code: 1006, reason: '', wasClean: false });
    clearTimeout(s.reconnectTimer);
    assert.ok(logs.some((l) => /^ws:fechado/.test(l)));
    assert.ok(logs.some((l) => /^ws:reconexão em \d+ ms/.test(l)));
  } finally {
    delete globalThis.AulaCastDebug;
  }
  const s2 = new SocketClient(() => {}, () => {});
  assert.doesNotThrow(() => s2.handleMessage({ data: '{"type":"PONG"}' }), 'sem o global, nada muda');
});
