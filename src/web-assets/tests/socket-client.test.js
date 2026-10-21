import test from 'node:test';
import assert from 'node:assert';
import {
  ConnectionState,
  RECONNECT_INTERVAL_MS,
  RECONNECT_FAST_ATTEMPTS,
  RECONNECT_MAX_INTERVAL_MS
} from '../js/config.js';
import { SocketClient } from '../js/socket-client.js';

test('RNF-08: mantem tentativas a cada 2s durante o primeiro minuto', () => {
  assert.strictEqual(RECONNECT_INTERVAL_MS, 2000);
  assert.strictEqual(RECONNECT_FAST_ATTEMPTS, 30);
  assert.strictEqual(RECONNECT_INTERVAL_MS * RECONNECT_FAST_ATTEMPTS, 60000);

  const client = new SocketClient(() => {}, () => {});
  client.reconnectAttempts = 1;
  assert.strictEqual(client.nextDelay(), 2000, 'primeira tentativa em 2s');
  client.reconnectAttempts = 30;
  assert.strictEqual(client.nextDelay(), 2000, 'ainda 2s no fim do primeiro minuto');
});

test('Passado o primeiro minuto, o intervalo cresce ate um teto', () => {
  const client = new SocketClient(() => {}, () => {});

  client.reconnectAttempts = 31;
  assert.ok(client.nextDelay() > 2000, 'passa a esperar mais que 2s');

  client.reconnectAttempts = 500;
  assert.strictEqual(client.nextDelay(), RECONNECT_MAX_INTERVAL_MS, 'nunca passa do teto');
});

test('Nunca desiste sozinho: segue em RECONNECTING em vez de DISCONNECTED', () => {
  const states = [];
  const client = new SocketClient(
    (state, attempts) => states.push({ state, attempts }),
    () => {}
  );

  // Muito além do antigo limite de 30 tentativas.
  client.reconnectAttempts = 999;
  client.manuallyStopped = false;

  client.handleClose();

  assert.strictEqual(states.length, 1);
  assert.strictEqual(states[0].state, ConnectionState.RECONNECTING);
  assert.notStrictEqual(states[0].state, ConnectionState.DISCONNECTED);

  client.clearReconnectTimer?.();
  if (client.reconnectTimer) clearTimeout(client.reconnectTimer);
});

test('manuallyStopped impede novas tentativas', () => {
  const states = [];
  const client = new SocketClient((state) => states.push(state), () => {});

  client.manuallyStopped = true;
  client.handleClose();

  assert.strictEqual(states.length, 0, 'nao deve reagendar quando parado de proposito');
  if (client.reconnectTimer) clearTimeout(client.reconnectTimer);
});

test('rttMs(): null até o primeiro PONG, depois o último RTT medido do PING/PONG', () => {
  const c = new SocketClient(() => {}, () => {});
  assert.strictEqual(c.rttMs(), null);
  c.pingEnviadoEm = Date.now() - 37;
  c.handleMessage({ data: JSON.stringify({ type: 'PONG' }) });
  assert.ok(c.rttMs() >= 37 && c.rttMs() < 1000);
  c.handleMessage({ data: JSON.stringify({ type: 'PONG' }) }); // PONG sem PING pendente
  assert.ok(c.rttMs() >= 37, 'mantém o último valor');
});

test('ws_reconexao: o evento sai ao reabrir, com atraso e código da queda; sem queda, nada', () => {
  const eventos = [];
  globalThis.AulaCastMetricas = { evento: (t, d) => eventos.push([t, d]) };
  const c = new SocketClient(() => {}, () => {});
  c.startHeartbeat = () => {};
  c.handleOpen();
  assert.deepStrictEqual(eventos, [], 'primeira conexão não é reconexão');
  c.handleClose({ code: 1006 });
  clearTimeout(c.reconnectTimer);
  c.handleOpen();
  delete globalThis.AulaCastMetricas;
  assert.deepStrictEqual(eventos, [['ws_reconexao', { atrasoMs: 2000, codigo: 1006, tentativas: 1 }]]);
});
