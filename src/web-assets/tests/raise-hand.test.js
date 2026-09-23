import test from 'node:test';
import assert from 'node:assert';
import { MaoLevantada } from '../js/raise-hand.js';

function criarBotao() {
  const botao = {
    attrs: {}, title: '', listeners: {},
    setAttribute(n, v) { botao.attrs[n] = v; },
    addEventListener(evt, fn) { (botao.listeners[evt] ||= []).push(fn); },
    clicar() { (botao.listeners.click || []).forEach((fn) => fn()); }
  };
  return botao;
}

function nova(enviar = () => true) {
  const botao = criarBotao();
  const enviadas = [];
  const mao = new MaoLevantada(botao, (m) => { enviadas.push(m); return enviar(m); });
  return { mao, botao, enviadas };
}

test('A mão começa baixada, com o rótulo de levantar', () => {
  const { botao, enviadas } = nova();
  assert.strictEqual(botao.attrs['aria-pressed'], 'false');
  assert.strictEqual(botao.attrs['aria-label'], 'Levantar a mão');
  assert.strictEqual(enviadas.length, 0, 'nada é enviado sem o aluno pedir');
});

test('Tocar levanta e manda RAISE_HAND ativo; tocar de novo abaixa', () => {
  const { botao, enviadas } = nova();
  botao.clicar();
  assert.deepStrictEqual(enviadas[0], { type: 'RAISE_HAND', payload: { active: true } });
  assert.strictEqual(botao.attrs['aria-pressed'], 'true', 'muda na hora, sem esperar a rede');
  assert.strictEqual(botao.attrs['aria-label'], 'Abaixar a mão');
  assert.strictEqual(botao.title, 'Abaixar a mão');

  botao.clicar();
  assert.deepStrictEqual(enviadas[1], { type: 'RAISE_HAND', payload: { active: false } });
  assert.strictEqual(botao.attrs['aria-pressed'], 'false');
});

test('O ACK do servidor é quem manda no estado final', () => {
  const { mao, botao } = nova();
  botao.clicar();
  mao.confirmar(false);
  assert.strictEqual(mao.levantada, false);
  assert.strictEqual(botao.attrs['aria-pressed'], 'false');

  mao.confirmar('talvez');
  assert.strictEqual(mao.levantada, false, 'ACK sem booleano é ignorado');
});

test('HAND_LOWERED abaixa e diz se a mão estava levantada', () => {
  const { mao, botao } = nova();
  botao.clicar();
  assert.strictEqual(mao.abaixadaPeloProfessor(), true);
  assert.strictEqual(botao.attrs['aria-pressed'], 'false');
  assert.strictEqual(mao.abaixadaPeloProfessor(), false, 'repetido não conta de novo');
});

test('Reconectar reenvia a mão só se ela estava levantada', () => {
  const { mao, botao, enviadas } = nova();
  mao.reenviarSeLevantada();
  assert.strictEqual(enviadas.length, 0);

  botao.clicar();
  mao.reenviarSeLevantada();
  assert.deepStrictEqual(enviadas.at(-1), { type: 'RAISE_HAND', payload: { active: true } });
});

test('Sem conexão, levantar fica guardado e sai na reconexão', () => {
  let online = false;
  const { mao, botao, enviadas } = nova(() => online);
  botao.clicar();
  assert.strictEqual(mao.levantada, true, 'o toque não se perde');

  online = true;
  mao.reenviarSeLevantada();
  assert.strictEqual(enviadas.length, 2);
  assert.deepStrictEqual(enviadas[1].payload, { active: true });
});
