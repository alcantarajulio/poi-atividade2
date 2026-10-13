import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';
const TARGET_PATH = __ENV.TARGET_PATH || '/cpu';
const VUS = parseInt(__ENV.VUS || '1', 10);
const THINK_TIME = parseFloat(__ENV.THINK_TIME || '0');
const DURATION = __ENV.DURATION || '60s';
const WARMUP = __ENV.WARMUP || '10s';
const SUMMARY = __ENV.SUMMARY || 'summary.json';

const MEASURE = '{scenario:measure}';
const MEASURE_OK = '{scenario:measure,expected_response:true}';

export const options = {
  scenarios: {
    warmup: {
      executor: 'constant-vus',
      vus: VUS,
      duration: WARMUP,
      gracefulStop: '0s',
    },
    measure: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
      startTime: WARMUP,
      gracefulStop: '30s',
    },
  },
  thresholds: {
    [`http_req_duration${MEASURE_OK}`]: ['max>=0'],
    [`http_req_failed${MEASURE}`]: ['rate>=0'],
    [`http_reqs${MEASURE}`]: ['count>=0'],
    [`http_reqs${MEASURE_OK}`]: ['count>=0'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  discardResponseBodies: true,
};

export default function () {
  const res = http.get(`${BASE_URL}${TARGET_PATH}`, { timeout: '60s' });
  check(res, { 'status is 200': (r) => r.status === 200 });
  if (THINK_TIME > 0) {
    sleep(-THINK_TIME * Math.log(1 - Math.random()));
  }
}

function parseSeconds(d) {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m)$/.exec(d);
  if (!m) return NaN;
  const v = parseFloat(m[1]);
  return m[2] === 'ms' ? v / 1000 : m[2] === 'm' ? v * 60 : v;
}

export function handleSummary(data) {
  const m = data.metrics;
  const val = (name) => (m[name] ? m[name].values : {});
  const dur = val(`http_req_duration${MEASURE_OK}`);
  const reqs = val(`http_reqs${MEASURE}`).count || 0;
  const reqsOk = val(`http_reqs${MEASURE_OK}`).count || 0;
  const errRate = val(`http_req_failed${MEASURE}`).rate || 0;
  const seconds = parseSeconds(DURATION);
  const num = (x) => (reqsOk > 0 && typeof x === 'number' ? x : null);

  const out = {
    base_url: BASE_URL,
    target_path: TARGET_PATH,
    vus: VUS,
    think_time_s: THINK_TIME,
    duration_s: seconds,
    warmup_s: parseSeconds(WARMUP),
    requests: reqs,
    requests_ok: reqsOk,
    rps: reqs / seconds,
    rps_ok: reqsOk / seconds,
    error_rate: errRate,
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
