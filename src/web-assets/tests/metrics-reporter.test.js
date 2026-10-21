import test from 'node:test';
import assert from 'node:assert';
import { MetricsReporter, lerConexao, lerAmbiente, limparDados } from '../js/metrics-reporter.js';
import { VideoStreamPlayer } from '../js/video-stream-player.js';

function montar({ ativo = true, leituras = [], rota = 'H.264' } = {}) {
  const saida = { logs: [], tabelas: [], enviados: [], env: [], eventos: [] };
  let agora = 0;
  let i = 0;
  const estado = { ativo };
  const r = new MetricsReporter({
    enviar: (m) => (m.type === 'ENV' ? saida.env : m.type === 'EVENT' ? saida.eventos : saida.enviados).push(m),
    ativo: () => estado.ativo,
    lerRtt: () => 42,
    lerVisivel: () => true,
    lerConexaoImpl: () => null,
    lerAmbienteImpl: () => ({ userAgent: 'UA' }),
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
    payload: {
      rota: 'H.264', fps: 30, mbps: 2, dropped: 3, droppedTotal: 3, lagMs: 180, bufferS: null, playbackRate: null,
      rttMs: 42, visivel: true, conexao: null
    }
  }]);
  assert.match(saida.logs[0], /^\[AulaCast métricas\] você: rota H\.264 \| 30 fps \| 2 Mbps \| perdidos 3 quadros \| atraso 180 ms$/);
});

test('MJPEG: manda só a rota, números nulos, sem inventar valores', () => {
  const { r, saida } = montar({ rota: 'MJPEG' });
  r.amostrar();
  assert.deepStrictEqual(saida.enviados[0], {
    type: 'METRICS',
    payload: {
      rota: 'MJPEG', fps: null, mbps: null, dropped: null, droppedTotal: null, lagMs: null, bufferS: null,
      playbackRate: null, rttMs: 42, visivel: true, conexao: null
    }
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
  assert.deepStrictEqual(timers, [2000]);
  r.parar();
  assert.deepStrictEqual(cancelados, [1]);
});

test('VideoStreamPlayer.estatisticas(): bytes lidos, quadros do navegador e atraso até o ao vivo', () => {
  const video = {
    classList: { remove() {} }, addEventListener() {}, currentTime: 10,
    getVideoPlaybackQuality: () => ({ totalVideoFrames: 300, droppedVideoFrames: 4 })
  };
  const p = new VideoStreamPlayer(video, { janela: undefined });
  assert.deepStrictEqual(p.estatisticas(), { rota: 'H.264', bytes: 0, quadros: 300, perdidos: 4, lagMs: null, bufferS: null, playbackRate: null });

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

test('METRICS: dropped é a diferença no intervalo, droppedTotal o acumulado, e bufferS/playbackRate vêm da leitura', () => {
  const { r, saida, avancar } = montar({ leituras: [
    leitura(0, 0, 2), { ...leitura(1_250_000, 100, 7), bufferS: 0.456, playbackRate: 1.05 }
  ] });
  r.amostrar();
  avancar(2000);
  r.amostrar();
  const p = saida.enviados[0].payload;
  assert.deepStrictEqual([p.dropped, p.droppedTotal, p.bufferS, p.playbackRate], [5, 7, 0.46, 1.05]);
});

test('Sem navigator.connection (Safari/Firefox) a conexão é null; com ele, o formato fixo', () => {
  assert.strictEqual(lerConexao({}), null);
  assert.strictEqual(lerConexao(undefined), null);
  assert.deepStrictEqual(lerConexao({ connection: { effectiveType: '4g', downlink: 9.5, rtt: 50 } }),
    { tipo: '4g', downlinkMbps: 9.5, rttMs: 50 });
  assert.deepStrictEqual(lerConexao({ connection: { effectiveType: '4g' } }),
    { tipo: '4g', downlinkMbps: null, rttMs: null });
});

test('ENV: campos cortados nos limites e conexão null quando indisponível', () => {
  const env = lerAmbiente(
    { userAgent: 'u'.repeat(300), platform: 'p'.repeat(60), userAgentData: { platform: 'macOS' }, language: 'l'.repeat(30) },
    { width: 1920, height: 1080 }, 2
  );
  assert.strictEqual(env.userAgent.length, 200);
  assert.strictEqual(env.plataforma, 'macOS');
  assert.strictEqual(lerAmbiente({ platform: 'p'.repeat(60) }).plataforma.length, 40);
  assert.strictEqual(env.idioma.length, 16);
  assert.deepStrictEqual([env.telaLarg, env.telaAlt, env.dpr, env.conexao], [1920, 1080, 2, null]);
});

test('ENV sai uma única vez, só quando o aluno está identificado/ativo', () => {
  const { r, saida, estado, avancar } = montar({ leituras: [leitura(0, 0), leitura(1, 1)] });
  estado.ativo = false;
  r.amostrar();
  assert.strictEqual(saida.env.length, 0);
  estado.ativo = true;
  r.amostrar();
  avancar(2000);
  r.amostrar();
  r.amostrar();
  assert.strictEqual(saida.env.length, 1);
  assert.deepStrictEqual(saida.env[0], { type: 'ENV', payload: { userAgent: 'UA' } });
});

test('ENV é reenviado depois de uma reconexão (novo CONNECTED), uma vez por conexão', () => {
  const { r, saida, estado } = montar({ leituras: [leitura(0, 0), leitura(1, 1), leitura(2, 2)] });
  estado.ativo = true;
  r.definirHabilitado(true);
  r.amostrar();
  r.amostrar();
  assert.strictEqual(saida.env.length, 1);
  r.definirHabilitado(true); // reconexão: o servidor mandou outro CONNECTED
  r.amostrar();
  r.amostrar();
  assert.strictEqual(saida.env.length, 2);
});

test('EVENT: só tipos da lista, dados planos limpos (<=6 chaves, textos <=80, números finitos)', () => {
  const { r, saida } = montar();
  assert.strictEqual(r.evento('chat', { texto: 'oi' }), false);
  assert.strictEqual(r.evento('rota', { de: 'a', para: 'b', motivo: 'm'.repeat(200), n: NaN, o: { x: 1 }, a: 1, b: 2, c: 3, d: 4 }), true);
  const d = saida.eventos[0].payload.dados;
  assert.strictEqual(saida.eventos[0].payload.tipo, 'rota');
  assert.strictEqual(d.motivo.length, 80);
  assert.ok(Object.keys(d).length <= 6);
  assert.ok(!('n' in d) && !('o' in d));
  assert.deepStrictEqual(limparDados(null), {});
});

test('EVENT: no máximo 5 por segundo; a janela libera depois de 1 s', () => {
  const { r, saida, avancar } = montar();
  for (let i = 0; i < 8; i += 1) r.evento('seek', { motivo: 'x' });
  assert.strictEqual(saida.eventos.length, 5);
  avancar(1000);
  assert.strictEqual(r.evento('seek', { motivo: 'x' }), true);
  assert.strictEqual(saida.eventos.length, 6);
});

test('EVENT e gancho global: só existem com a flag; desligar remove o gancho', () => {
  const enviados = [];
  const r = new MetricsReporter({ enviar: (m) => enviados.push(m), lerEstatisticas: () => null });
  delete globalThis.AulaCastMetricas; // vazado de testes anteriores
  assert.strictEqual(r.evento('rota', {}), false);
  assert.strictEqual(globalThis.AulaCastMetricas, undefined);
  r.definirHabilitado(true);
  globalThis.AulaCastMetricas.evento('quota', { acao: 'x' });
  assert.strictEqual(enviados.length, 1);
  r.definirHabilitado(false);
  assert.strictEqual(globalThis.AulaCastMetricas, undefined);
  assert.strictEqual(enviados.length, 1);
});
