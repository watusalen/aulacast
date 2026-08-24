import test from 'node:test';
import assert from 'node:assert';
import { ConnectionState } from '../js/config.js';

test('ConnectionState possui todos os estados de conexão necessários', () => {
  assert.strictEqual(ConnectionState.DISCONNECTED, 'disconnected');
  assert.strictEqual(ConnectionState.CONNECTING, 'connecting');
  assert.strictEqual(ConnectionState.CONNECTED, 'connected');
  assert.strictEqual(ConnectionState.RECONNECTING, 'reconnecting');
});