import test from 'node:test';
import assert from 'node:assert';
import { erroDoNome, normalizarNome, salvarIdentidade, carregarIdentidade } from '../js/student-identity.js';

test('Nome é obrigatório e não pode ser trivial', () => {
  assert.strictEqual(erroDoNome('Ana Beatriz'), null);
  assert.match(erroDoNome(''), /Informe seu nome/);
  assert.match(erroDoNome('   '), /Informe seu nome/);
  assert.match(erroDoNome('A'), /curto/);
});

test('Espaços sobrando no nome não viram nomes diferentes na lista do professor', () => {
  assert.strictEqual(normalizarNome('  Ana   Beatriz  '), 'Ana Beatriz');
  assert.strictEqual(normalizarNome(undefined), '');
});

test('A identidade sobrevive a recarregar a página', () => {
  const guardado = {};
  globalThis.sessionStorage = {
    getItem: (k) => (k in guardado ? guardado[k] : null),
    setItem: (k, v) => { guardado[k] = v; }
  };

  salvarIdentidade({ name: 'Ana Beatriz' });
  assert.deepStrictEqual(carregarIdentidade(), { name: 'Ana Beatriz' });
});

test('Identidade guardada sem nome válido é descartada', () => {
  const guardado = { 'aulacast.identidade': JSON.stringify({ name: '' }) };
  globalThis.sessionStorage = {
    getItem: (k) => (k in guardado ? guardado[k] : null),
    setItem: (k, v) => { guardado[k] = v; }
  };

  assert.strictEqual(carregarIdentidade(), null);
});

test('Sem sessionStorage disponível, a aula não quebra', () => {
  delete globalThis.sessionStorage;
  assert.doesNotThrow(() => salvarIdentidade({ name: 'Ana' }));
  assert.strictEqual(carregarIdentidade(), null);
});

test('Nome é contado em letras, como no servidor, e tem teto', async () => {
  const { erroDoNome, TAMANHO_MAXIMO_NOME } = await import('../js/student-identity.js');
  // "é" decomposto (e + acento) é uma letra só: o servidor recusaria.
  assert.ok(erroDoNome('e\u0301'));
  assert.ok(erroDoNome('👍'));
  assert.strictEqual(erroDoNome('a'.repeat(TAMANHO_MAXIMO_NOME)), null);
  assert.ok(erroDoNome('a'.repeat(TAMANHO_MAXIMO_NOME + 1)));
});
