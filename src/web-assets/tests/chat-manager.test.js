import test from 'node:test';
import assert from 'node:assert';

test('Formatação de mensagens do professor e alunos', () => {
  const formatAuthor = (author, isProf) => isProf ? `${author} (Professor)` : author;
  
  assert.strictEqual(formatAuthor('Matusalém', true), 'Matusalém (Professor)');
  assert.strictEqual(formatAuthor('Carlos - PC 04', false), 'Carlos - PC 04');
});