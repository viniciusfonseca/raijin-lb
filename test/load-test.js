import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    ramping_test: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '15s', target: __ENV['VUS'] || 100 },
        { duration: '30s', target: __ENV['VUS'] || 100 },
      ],
      gracefulRampDown: '5s',
    },
  },
};

export default function () {
  check(http.get(__ENV['TARGET_LB_URL']), {
    'status is 200': (r) => r.status === 200,
  });
}