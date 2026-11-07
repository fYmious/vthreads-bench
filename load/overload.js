// Нагрузочный тест k6, ОТКРЫТАЯ модель: запросы приходят с заданной частотой
// независимо от того, успевает ли сервис отвечать (как в реальном трафике).
// Нужен для проверки поведения при перегрузке: ошибки, рост задержек, пропущенные запросы.
//   k6 run -e RATE=3000 -e DURATION=45s -e MS=100 load/overload.js
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    open: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 1000),
      timeUnit: '1s',
      duration: __ENV.DURATION || '45s',
      preAllocatedVUs: Number(__ENV.PREALLOC || 2000),
      maxVUs: Number(__ENV.MAXVUS || 20000),
    },
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const url = `http://localhost:8080/work?ms=${__ENV.MS || 100}&calls=${__ENV.CALLS || 1}`;
  // запрос дольше 10 с считается неуспешным (клиент не станет ждать вечно)
  const res = http.get(url, { timeout: __ENV.TIMEOUT || '10s' });
  check(res, { 'status 200': (r) => r.status === 200 });
}
