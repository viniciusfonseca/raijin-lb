import http from 'k6';
import { check } from 'k6';

export const options = {
  vus: 10,
  duration: '30s',
};

export default function () {
  check(http.get(__ENV['TARGET_LB_URL']), {
    'status is 200': (r) => r.status === 200,
  });
}