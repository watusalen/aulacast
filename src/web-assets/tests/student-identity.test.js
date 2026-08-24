import test from 'node:test';
import assert from 'node:assert';
import {
  matriculaValida,
  normalizarMatricula,
  erroDaMatricula,
  erroDoNome,
  MATRICULA_TAMANHO
} from '../js/student-identity.js';

test('Matrícula no formato 202XXXXTADSXXXX é aceita', () => {
  assert.strictEqual(MATRICULA_TAMANHO, 15);
  assert.ok(matriculaValida('2021234TADS5678'));
  assert.ok(matriculaValida('2020000TADS0000'));
  assert.ok(matriculaValida('2029999TADS9999'));
});

test('Minúsculas e espaços são normalizados antes de validar', () => {
  assert.strictEqual(normalizarMatricula('  2021234tads5678 '), '2021234TADS5678');
  assert.ok(matriculaValida('  2021234tads5678 '));
});

test('Matrículas fora do padrão são recusadas', () => {
  assert.ok(!matriculaValida(''), 'vazia');
  assert.ok(!matriculaValida('2021234TADS567'), 'curta demais');
  assert.ok(!matriculaValida('2021234TADS56789'), 'longa demais');
  assert.ok(!matriculaValida('1991234TADS5678'), 'nao comeca com 202');
  assert.ok(!matriculaValida('2021234INFO5678'), 'curso errado');
  assert.ok(!matriculaValida('202ABCDTADS5678'), 'letras onde deveria ter numero');
  assert.ok(!matriculaValida('2021234TADSABCD'), 'letras no bloco final');
  assert.ok(!matriculaValida('2021234TADS567X'), 'digito invalido no fim');
});

test('A mensagem de erro aponta o problema específico', () => {
  assert.match(erroDaMatricula(''), /Informe/);
  assert.match(erroDaMatricula('2021234TADS567'), /15 caracteres/);
  assert.match(erroDaMatricula('1991234TADS5678'), /começar com 202/);
  assert.match(erroDaMatricula('2021234INFO5678'), /TADS/);
  assert.match(erroDaMatricula('202ABCDTADS5678'), /números/);
  assert.strictEqual(erroDaMatricula('2021234TADS5678'), null, 'valida nao gera erro');
});

test('Nome é obrigatório e não pode ser trivial', () => {
  assert.match(erroDoNome(''), /Informe/);
  assert.match(erroDoNome('   '), /Informe/);
  assert.match(erroDoNome('A'), /curto/);
  assert.strictEqual(erroDoNome('Ana Beatriz Sousa'), null);
});
