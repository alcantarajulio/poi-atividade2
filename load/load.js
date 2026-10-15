import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';
const TARGET_PATH = __ENV.TARGET_PATH || '/cpu';
const VUS = parseInt(__ENV.VUS || '1', 10);
const THINK_TIME = parseFloat(__ENV.THINK_TIME || '0');
const DURATION = __ENV.DURATION || '60s';
const WARMUP = __ENV.WARMUP || '10s';
const SUMMARY = __ENV.SUMMARY || 'summary.json';

function parseSeconds(d) {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m)$/.exec(d);
  if (!m) return NaN;
  const v = parseFloat(m[1]);
  return m[2] === 'ms' ? v / 1000 : m[2] === 'm' ? v * 60 : v;
}

const WARMUP_S = parseSeconds(WARMUP);
const DURATION_S = parseSeconds(DURATION);

// Os mesmos VUs fazem o aquecimento e a medição, sem pausa entre os dois. Antes eram dois
// cenários do k6: na virada, todos os VUs da medição disparavam juntos (rajada) enquanto o
// servidor ainda processava as requisições interrompidas do aquecimento. Agora cada
// requisição recebe a tag "phase" conforme o instante em que foi emitida:
//   warmup  -> descartada
//   measure -> conta (janela de DURATION segundos)
//   tail    -> não deveria existir (nenhuma iteração começa depois do fim)
// O gracefulStop deixa terminar as requisições em andamento no fim; elas entram na medição
// com a sua latência real (sem censura), e a vazão é "requisições emitidas na janela / DURATION".
const MEASURE = '{phase:measure}';
const MEASURE_OK = '{phase:measure,expected_response:true}';

export const options = {
  scenarios: {
    load: {
      executor: 'constant-vus',
      vus: VUS,
      duration: `${Math.round((WARMUP_S + DURATION_S) * 1000)}ms`,
      gracefulStop: '30s',
    },
  },
  // Os limiares sempre passam; existem só para o k6 criar estas sub-métricas.
  thresholds: {
    [`http_req_duration${MEASURE_OK}`]: ['max>=0'],
    [`http_req_failed${MEASURE}`]: ['rate>=0'],
    [`http_reqs${MEASURE}`]: ['count>=0'],
    [`http_reqs${MEASURE_OK}`]: ['count>=0'],
    'http_reqs{phase:tail}': ['count>=0'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  discardResponseBodies: true,
};

export default function () {
  const t = (Date.now() - exec.scenario.startTime) / 1000;
  const phase = t < WARMUP_S ? 'warmup' : t < WARMUP_S + DURATION_S ? 'measure' : 'tail';
  const res = http.get(`${BASE_URL}${TARGET_PATH}`, { timeout: '60s', tags: { phase } });
  check(res, { 'status is 200': (r) => r.status === 200 });
  if (THINK_TIME > 0) {
    sleep(-THINK_TIME * Math.log(1 - Math.random()));
  }
}

export function handleSummary(data) {
  const m = data.metrics;
  const val = (name) => (m[name] ? m[name].values : {});
  const dur = val(`http_req_duration${MEASURE_OK}`);
  const reqs = val(`http_reqs${MEASURE}`).count || 0;
  const reqsOk = val(`http_reqs${MEASURE_OK}`).count || 0;
  const reqsTail = val('http_reqs{phase:tail}').count || 0;
  const errRate = val(`http_req_failed${MEASURE}`).rate || 0;
  const num = (x) => (reqsOk > 0 && typeof x === 'number' ? x : null);

  // O k6 não expõe o instante de início. Como o handleSummary roda logo ao fim do teste,
  // início ≈ agora - duração total do teste. O analisador usa isto para alinhar a janela
  // dos coletores; o run.sh grava também o horário de lançamento do k6 como reserva.
  const endMs = Date.now();
  const runMs = data.state && typeof data.state.testRunDurationMs === 'number' ? data.state.testRunDurationMs : null;
  const startMs = runMs === null ? null : endMs - runMs;

  const out = {
    base_url: BASE_URL,
    target_path: TARGET_PATH,
    vus: VUS,
    think_time_s: THINK_TIME,
    duration_s: DURATION_S,
    warmup_s: WARMUP_S,
    requests: reqs,
    requests_ok: reqsOk,
    requests_tail: reqsTail,
    rps: reqs / DURATION_S,
    rps_ok: reqsOk / DURATION_S,
    error_rate: errRate,
    run_start_epoch: startMs === null ? null : startMs / 1000,
    run_end_epoch: endMs / 1000,
    measure_start_epoch: startMs === null ? null : startMs / 1000 + WARMUP_S,
    measure_end_epoch: startMs === null ? null : startMs / 1000 + WARMUP_S + DURATION_S,
    latency_ms: {
      avg: num(dur.avg),
      min: num(dur.min),
      p50: num(dur.med),
      p90: num(dur['p(90)']),
      p95: num(dur['p(95)']),
      p99: num(dur['p(99)']),
      max: num(dur.max),
    },
  };

  const f = (x) => (x === null ? '-' : x.toFixed(1));
  const l = out.latency_ms;
  const line =
    `vus=${VUS} reqs=${reqs} ok/s=${out.rps_ok.toFixed(1)} ` +
    `p50=${f(l.p50)}ms p95=${f(l.p95)}ms p99=${f(l.p99)}ms ` +
    `err=${(errRate * 100).toFixed(2)}%\n`;

  return { stdout: line, [SUMMARY]: JSON.stringify(out, null, 2) };
}
