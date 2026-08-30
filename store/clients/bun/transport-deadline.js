
export const default_transport_deadline_ms = 60000;

const query_response_grace_ms = 1000;

export function transport_deadline_ms(configured_ms, query_execution_ms, query_deadline_p) {
  const query_response_ms = (query_deadline_p ? (query_execution_ms + query_response_grace_ms) : 0);
  return ((query_response_ms > configured_ms) ? query_response_ms : configured_ms);
}
