// worker-example.js — minimal runnable Cloudflare Worker over a Fram server.
//
// Routes:
//   GET  /            usage
//   GET  /health      server rpc/status (proves the whole chain)
//   POST /fact        body {"t1":"@bench1","t2":"title","t3":"hello"}
//   GET  /facts?t2=X   matching rows (&t1=@id also supported)
//   GET  /bench?n=20  n sequential query round-trips, timing summary
//
// Config: SHIM_URL + FRAM_SPACE_ID vars, SHIM_TOKEN secret.
// The Worker holds NO state — every isolate, cold or warm, is one fetch() away
// from the durable Fram server behind the shim.
import { framClient, listValues, recordFields, tripleQuery } from './worker-client.js';

const json = (v, status = 200) =>
  new Response(JSON.stringify(v, null, 1) + '\n',
    { status, headers: { 'content-type': 'application/json' } });

export default {
  async fetch(request, env) {
    const fram = framClient({
      url: env.SHIM_URL,
      token: env.SHIM_TOKEN,
      space: env.FRAM_SPACE_ID,
    });
    const u = new URL(request.url);
    try {
      if (u.pathname === '/health') return json(await fram.status());

      if (u.pathname === '/fact' && request.method === 'POST') {
        const body = await request.json();
        const t1 = body.t1;
        const t2 = body.t2;
        const t3 = body.t3;
        return json(await fram.assert(t1, t2, t3,
          { expectedVersion: body.expectedVersion }));
      }

      if (u.pathname === '/facts') {
        const pat = {
          t1: u.searchParams.get('t1') ?? u.searchParams.get('l'),
          t2: u.searchParams.get('t2') ?? u.searchParams.get('p'),
        };
        return json(await fram.query(tripleQuery(pat)));
      }

      if (u.pathname === '/bench') {
        const n = Math.min(200, Number(u.searchParams.get('n')) || 20);
        const q = tripleQuery({ t2: u.searchParams.get('t2') || 'title' });
        const times = [];
        let rows = 0;
        for (let i = 0; i < n; i++) {
          const t0 = Date.now();
          const res = await fram.query(q);
          times.push(Date.now() - t0);
          if (res.payload) {
            const [encodedRows] = recordFields(res.payload, 'query/rows', 1);
            rows = listValues(encodedRows).length;
          }
        }
        times.sort((a, b) => a - b);
        return json({
          n, rows,
          p50_ms: times[Math.floor(n / 2)],
          min_ms: times[0], max_ms: times[n - 1],
          note: 'each round-trip = Worker -> shim (HTTP) -> Fram server (TCP) -> back',
        });
      }

      return new Response(
        'fram worker\n' +
        '  GET  /health\n' +
        '  POST /fact   {"t1":"@bench1","t2":"title","t3":"hello"}\n' +
        '  GET  /facts?t2=title\n' +
        '  GET  /bench?n=20&t2=title\n');
    } catch (e) {
      return json({ error: String(e && e.message || e) }, 502);
    }
  },
};
