import test from 'node:test';
import assert from 'node:assert';
import { MetricsReporter } from '../js/metrics-reporter.js';
import { VideoStreamPlayer } from '../js/video-stream-player.js';

function montar({ ativo = true, leituras = [], rota = 'H.264' } = {}) {
  const saida = { logs: [], tabelas: [], enviados: [] };
  let agora = 0;
  let i = 0;
  const estado = { ativo };
  const r = new MetricsReporter({
    enviar: (m) => saida.enviados.push(m),
    ativo: () => estado.ativo,
    lerEstatisticas: () => (rota === 'H.264' ? leituras[Math.min(i++, leituras.length - 1)] : { rota }),
    log: { log: (t) => saida.logs.push(t), table: (l) => saida.tabelas.push(l) },
    agora: () => agora
  });
  r.definirHabilitado(true);
  return { r, saida, estado, avancar: (ms) => { agora += ms; } };
}

const leitura = (bytes, quadros, perdidos = 0, lagMs = 120) => ({ rota: 'H.264', bytes, quadros, perdidos, lagMs });

test('H.264: calcula fps, Mbps, perdidos e atraso entre duas leituras e manda METRICS', () => {
  const { r, saida, avancar } = montar({ leituras: [leitura(0, 0), leitura(1_250_000, 150, 3, 180.4)] });
  r.amostrar(); // fixa a base, nada a mostrar ainda
  assert.strictEqual(saida.enviados.length, 0);
  avancar(5000);
  r.amostrar();

  assert.deepStrictEqual(saida.enviados, [{
    type: 'METRICS',
    payload: { rota: 'H.264', fps: 30, mbps: 2, dropped: 3, lagMs: 180 }
  }]);
  assert.match(saida.logs[0], /^\[AulaCast métricas\] você: rota H\.264 \| 30 fps \| 2 Mbps \| perdidos 3 quadros \| atraso 180 ms$/);
});

test('MJPEG: manda só a rota, números nulos, sem inventar valores', () => {
  const { r, saida } = montar({ rota: 'MJPEG' });
  r.amostrar();
  assert.deepStrictEqual(saida.enviados[0], {
    type: 'METRICS',
    payload: { rota: 'MJPEG', fps: null, mbps: null, dropped: null, lagMs: null }
  });
  assert.match(saida.logs[0], /rota MJPEG \| n\/d \| n\/d \| perdidos n\/d \| atraso n\/d/);
});

test('Silencioso com aula pausada/encerrada ou aluno sem identificação, e recomeça a base ao voltar', () => {
  const { r, saida, estado, avancar } = montar({ leituras: [leitura(0, 0), leitura(500, 10), leitura(2_500_000, 300)] });
  estado.ativo = false;
  r.amostrar();
  assert.deepStrictEqual([saida.logs.length, saida.enviados.length], [0, 0]);

  estado.ativo = true;
  r.amostrar(); // base
  avancar(5000);
  r.amostrar();
  assert.strictEqual(saida.enviados.length, 1);

  estado.ativo = false;
  avancar(5000);
  r.amostrar();
  assert.strictEqual(saida.enviados.length, 1, 'pausado: nada novo');
  assert.strictEqual(r.anterior, null, 'a pausa descarta a base (a diferença atravessaria a pausa)');
});

test('Contador que recuou (nova conexão de vídeo) vira null, nunca número negativo', () => {
  const { r, saida, avancar } = montar({ leituras: [leitura(5000, 100), leitura(100, 10)] });
  r.amostrar();
  avancar(5000);
  r.amostrar();
  const p = saida.enviados[0].payload;
  assert.strictEqual(p.fps, null);
  assert.strictEqual(p.mbps, null);
});

test('METRICS_TABLE: uma linha de resumo e console.table com as linhas, sem mexer na página', () => {
  const { r, saida } = montar();
  r.aoReceberTabela({
    alunos: 2, alunosH264: 1, alunosMJPEG: 1, telaFps: 29.96, mediaFps: 28, minimoFps: 25, mbps: 4.25,
    rows: [
      { nome: 'Ana "A"', rota: 'H.264', fps: 30, mbps: 2, dropped: 0, lagMs: 100, extra: 'x' },
      { nome: 'Bia', rota: 'MJPEG', fps: null, mbps: null, dropped: null, lagMs: null }
    ]
  });
  assert.match(saida.logs[0], /turma: 2 alunos \(H\.264 1 \/ MJPEG 1\) \| tela 30 fps \| por aluno: média 28, mínimo 25 fps \| 4\.3 Mbps/);
  assert.deepStrictEqual(saida.tabelas[0], [
    { nome: 'Ana "A"', rota: 'H.264', fps: 30, mbps: 2, dropped: 0, lagMs: 100 },
    { nome: 'Bia', rota: 'MJPEG', fps: null, mbps: null, dropped: null, lagMs: null }
  ]);
  r.aoReceberTabela(null);
  r.aoReceberTabela({ rows: 'lixo' });
  assert.strictEqual(saida.tabelas.length, 2);
  assert.deepStrictEqual(saida.tabelas[1], []);
});

test('iniciar() é idempotente e parar() desliga o relógio', () => {
  const timers = [];
  const cancelados = [];
  const r = new MetricsReporter({
    enviar() {}, lerEstatisticas: () => null, log: { log() {}, table() {} },
    setIntervalImpl: (f, ms) => { timers.push(ms); return timers.length; },
    clearIntervalImpl: (t) => cancelados.push(t)
  });
  r.definirHabilitado(true);
  r.iniciar();
  r.iniciar();
  assert.deepStrictEqual(timers, [5000]);
  r.parar();
  assert.deepStrictEqual(cancelados, [1]);
});

test('VideoStreamPlayer.estatisticas(): bytes lidos, quadros do navegador e atraso até o ao vivo', () => {
  const video = {
    classList: { remove() {} }, addEventListener() {}, currentTime: 10,
    getVideoPlaybackQuality: () => ({ totalVideoFrames: 300, droppedVideoFrames: 4 })
  };
  const p = new VideoStreamPlayer(video, { janela: undefined });
  assert.deepStrictEqual(p.estatisticas(), { rota: 'H.264', bytes: 0, quadros: 300, perdidos: 4, lagMs: null });

  p.bytesRecebidos = 1234;
  p.sourceBuffer = { buffered: { length: 1, end: () => 10.25 } };
  const e = p.estatisticas();
  assert.strictEqual(e.bytes, 1234);
  assert.strictEqual(e.lagMs, 250);

  delete video.getVideoPlaybackQuality;
  assert.strictEqual(p.estatisticas().quadros, null, 'sem a API, não inventa');
});

test('Sem o aviso do servidor (build normal) o reporter fica ocioso: sem relógio, envio nem console', () => {
  const saida = { logs: [], enviados: [], timers: 0 };
  const r = new MetricsReporter({
    enviar: (m) => saida.enviados.push(m), lerEstatisticas: () => ({ rota: 'MJPEG' }),
    log: { log: (t) => saida.logs.push(t), table: (l) => saida.logs.push(l) },
    setIntervalImpl: () => { saida.timers += 1; return 1; }
  });
  r.iniciar();
  r.amostrar();
  r.aoReceberTabela({ alunos: 1, rows: [] });
  assert.deepStrictEqual([saida.timers, saida.logs.length, saida.enviados.length], [0, 0, 0]);

  r.definirHabilitado(true);
  r.iniciar();
  assert.strictEqual(saida.timers, 1);
  r.definirHabilitado(false); // o servidor reconectou sem o aviso
  assert.strictEqual(r.timer, null);
});
