import test from 'node:test';
import assert from 'node:assert';
import { PresenceReporter } from '../js/presence-reporter.js';

/**
 * Documento falso que reproduz a armadilha real do navegador: durante o evento `blur`,
 * `hasFocus()` ainda pode responder `true` porque a troca de foco não terminou.
 */
function fakeDoc({ visibilityState = 'visible', hasFocus = true } = {}) {
  return {
    visibilityState,
    hasFocus: () => hasFocus,
    addEventListener() {},
    removeEventListener() {}
  };
}

function coletor() {
  const enviados = [];
  return {
    enviados,
    enviar: (m) => enviados.push(m.payload.visible)
  };
}

test('Sair da página clicando em outro app é detectado, mesmo com hasFocus() atrasado', () => {
  const c = coletor();
  // hasFocus ainda true: é exatamente o estado enganoso durante o blur.
  const p = new PresenceReporter(c.enviar, fakeDoc({ hasFocus: true }));

  p.sincronizar();
  assert.deepStrictEqual(c.enviados, [true], 'começa assistindo');

  p.aoPerderFoco();
  assert.deepStrictEqual(c.enviados, [true, false], 'perder o foco reporta que não está vendo');
});

test('Voltar o foco reporta que está assistindo de novo', () => {
  const c = coletor();
  const p = new PresenceReporter(c.enviar, fakeDoc());

  p.sincronizar();
  p.aoPerderFoco();
  p.aoGanharFoco();

  assert.deepStrictEqual(c.enviados, [true, false, true]);
});

test('Trocar de aba (visibilidade oculta) reporta que não está vendo', () => {
  const c = coletor();
  const doc = fakeDoc();
  const p = new PresenceReporter(c.enviar, doc);

  p.sincronizar();
  doc.visibilityState = 'hidden';
  p.aoMudarVisibilidade();

  assert.deepStrictEqual(c.enviados, [true, false]);
});

test('Não reenvia o mesmo estado repetidamente', () => {
  const c = coletor();
  const p = new PresenceReporter(c.enviar, fakeDoc());

  p.sincronizar();
  p.aoPerderFoco();
  p.aoPerderFoco();
  p.aoPerderFoco();

  assert.deepStrictEqual(c.enviados, [true, false], 'blur repetido não gera tráfego extra');
});

test('sincronizar() reenvia mesmo sem mudança, pois a conexão é nova', () => {
  const c = coletor();
  const p = new PresenceReporter(c.enviar, fakeDoc());

  p.sincronizar();
  p.sincronizar();

  assert.deepStrictEqual(c.enviados, [true, true], 'reconexão exige reenviar o estado');
});

test('Aba oculta e sem foco continua sendo "não está vendo" ao sincronizar', () => {
  const c = coletor();
  const p = new PresenceReporter(c.enviar, fakeDoc({ visibilityState: 'hidden', hasFocus: false }));

  p.sincronizar();
  assert.deepStrictEqual(c.enviados, [false]);
});
