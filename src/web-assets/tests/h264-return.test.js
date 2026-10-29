import test from 'node:test';
import assert from 'node:assert';
import { RetornoAoH264, ESPERAS_DE_RETORNO_MS } from '../js/h264-return.js';

/** Relógio de mentira: guarda o que foi marcado e deixa o teste disparar na mão. */
function relogio() {
  const r = { marcados: [], cancelados: 0 };
  r.setTimer = (fn, ms) => { const t = { fn, ms }; r.marcados.push(t); return t; };
  r.clearTimer = () => { r.cancelados += 1; };
  r.disparar = (i = r.marcados.length - 1) => r.marcados[i].fn();
  return r;
}

function montar({ podeTentar = () => true, sorteio = () => 0 } = {}) {
  const r = relogio();
  const tentadas = [];
  const retorno = new RetornoAoH264({
    tentar: () => tentadas.push(1),
    podeTentar,
    esperas: [100, 200, 400],
    setTimer: r.setTimer,
    clearTimer: r.clearTimer,
    sorteio
  });
  return { r, retorno, tentadas };
}

test('as esperas padrão crescem e a última se repete', () => {
  assert.deepStrictEqual(ESPERAS_DE_RETORNO_MS, [30_000, 60_000, 120_000, 300_000]);
});

test('agendar marca a primeira espera e, ao disparar, tenta uma vez', () => {
  const { r, retorno, tentadas } = montar();
  retorno.agendar();
  assert.strictEqual(r.marcados.length, 1);
  assert.strictEqual(r.marcados[0].ms, 100);
  assert.strictEqual(tentadas.length, 0);
  r.disparar();
  assert.strictEqual(tentadas.length, 1);
});

test('dois pedidos seguidos de agendamento geram um relógio só', () => {
  const { r, retorno } = montar();
  retorno.agendar();
  retorno.agendar();
  assert.strictEqual(r.marcados.length, 1);
});

test('cada nova queda espera mais e a última espera se repete', () => {
  const { r, retorno } = montar();
  for (let i = 0; i < 5; i += 1) {
    retorno.agendar();
    r.disparar();
  }
  assert.deepStrictEqual(r.marcados.map((m) => m.ms), [100, 200, 400, 400, 400]);
});

test('a espera é sorteada entre 1x e 2x a base: cada participante volta num momento diferente', () => {
  const sorteios = [0, 0.25, 0.5, 0.999];
  const esperas = sorteios.map((s) => {
    const { r, retorno } = montar({ sorteio: () => s });
    retorno.agendar();
    return r.marcados[0].ms;
  });
  assert.deepStrictEqual(esperas, [100, 125, 150, 200]);
  assert.ok(new Set(esperas).size === esperas.length, 'sorteios diferentes dão voltas em momentos diferentes');
});

test('com o sorteio padrão (Math.random), toda espera cai dentro de [base, 2 x base)', () => {
  for (let i = 0; i < 200; i += 1) {
    const r = relogio();
    const retorno = new RetornoAoH264({ tentar() {}, esperas: [100], setTimer: r.setTimer, clearTimer: r.clearTimer });
    retorno.agendar();
    const ms = r.marcados[0].ms;
    assert.ok(ms >= 100 && ms <= 200, `espera fora da faixa: ${ms}`);
  }
});

test('sem poder tentar (ex.: transmissão encerrada), não tenta e marca de novo', () => {
  let pode = false;
  const { r, retorno, tentadas } = montar({ podeTentar: () => pode });
  retorno.agendar();
  r.disparar();
  assert.strictEqual(tentadas.length, 0);
  assert.strictEqual(r.marcados.length, 2, 'ficou marcado para mais tarde');
  pode = true;
  r.disparar();
  assert.strictEqual(tentadas.length, 1);
});

test('recuperou zera a espera e cancela o que estava marcado', () => {
  const { r, retorno } = montar();
  retorno.agendar();
  r.disparar();
  retorno.agendar();
  retorno.recuperou();
  assert.strictEqual(r.cancelados, 1);
  retorno.agendar();
  assert.strictEqual(r.marcados[r.marcados.length - 1].ms, 100, 'recomeça da primeira espera');
});

test('hora errada (pausada, encerrada, aba oculta) não gasta prova nem sobe a espera', () => {
  let pode = false;
  const { r, retorno, tentadas } = montar({ podeTentar: () => pode });
  retorno.agendar();
  for (let i = 0; i < 6; i += 1) r.disparar();
  assert.strictEqual(retorno.tentativas, 0, 'nenhuma prova foi feita');
  assert.deepStrictEqual(new Set(r.marcados.map((m) => m.ms)), new Set([100]), 'espera continua a da primeira prova');
  pode = true;
  r.disparar();
  assert.strictEqual(tentadas.length, 1);
  assert.strictEqual(retorno.tentativas, 1);
});

test('teto de provas: falha permanente não tenta para sempre; recuperou() libera de novo', () => {
  const r = relogio();
  const retorno = new RetornoAoH264({ tentar() {}, esperas: [1], maximo: 3, setTimer: r.setTimer, clearTimer: r.clearTimer, sorteio: () => 0 });
  for (let i = 0; i < 3; i += 1) {
    retorno.agendar();
    r.disparar();
  }
  const marcadosAntes = r.marcados.length;
  retorno.agendar();
  assert.strictEqual(r.marcados.length, marcadosAntes, 'depois de 3 provas não marca mais nada');
  retorno.recuperou();
  retorno.agendar();
  assert.strictEqual(r.marcados.length, marcadosAntes + 1);
});

test('tentar() devolvendo false (prova já em andamento) deixa a próxima marcada', () => {
  const r = relogio();
  const retorno = new RetornoAoH264({ tentar: () => false, esperas: [100], setTimer: r.setTimer, clearTimer: r.clearTimer, sorteio: () => 0 });
  retorno.agendar();
  r.disparar();
  assert.strictEqual(r.marcados.length, 2);
});
