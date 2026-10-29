// Нагрузочный тест k6. Запуск:
//   k6 run -e VUS=500 -e DURATION=60s -e MS=100 -e CALLS=1 load/work.js
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    load: {
      executor: 'constant-vus', // закрытая модель: каждый VU шлёт следующий запрос после ответа
      vus: Number(__ENV.VUS || 500),
      duration: __ENV.DURATION || '60s',
    },
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const url = `http://localhost:8080/work?ms=${__ENV.MS || 100}&calls=${__ENV.CALLS || 1}`;
  const res = http.get(url);
  check(res, { 'status 200': (r) => r.status === 200 });
}
