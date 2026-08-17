#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch:?}"' EXIT

cat >"$scratch/fixture.jsonl" <<'JSONL'
{"ts":"2026-08-01T01:00:00Z","op":"set-body","module":"m1","def":"a","wall_ms":10,"payload_bytes":10,"module_bytes":1000,"accepted":true,"reject_reason":null,"recompile_ms":null,"retry_seq":0}
{"ts":"2026-08-01T02:00:00Z","op":"set-body","module":"m1","def":"a","wall_ms":20,"payload_bytes":10,"module_bytes":1000,"accepted":false,"reject_reason":"missing target","recompile_ms":null,"retry_seq":1}
{"ts":"2026-08-01T03:00:00Z","op":"set-body","module":"m1","def":"a","wall_ms":30,"payload_bytes":10,"module_bytes":1000,"accepted":true,"reject_reason":null,"recompile_ms":null,"retry_seq":2}
{"ts":"2026-08-01T04:00:00Z","op":"add-def","module":"m2","def":"b","wall_ms":100,"payload_bytes":10,"module_bytes":20000,"accepted":true,"reject_reason":null,"recompile_ms":null,"retry_seq":0}
{"ts":"2026-08-01T05:00:00Z","op":"add-def","module":"m2","def":"b","wall_ms":200,"payload_bytes":10,"module_bytes":20000,"accepted":false,"reject_reason":"compile","recompile_ms":null,"retry_seq":1}
{"ts":"2026-08-01T06:00:00Z","op":"show","module":null,"def":"a","wall_ms":5,"payload_bytes":10,"module_bytes":null,"accepted":true,"reject_reason":null,"recompile_ms":null,"retry_seq":0}
{"ts":"2026-08-02T01:00:00Z","op":"add-def","module":"m3","def":"c","wall_ms":300,"payload_bytes":10,"module_bytes":300000,"accepted":false,"reject_reason":"compile","recompile_ms":null,"retry_seq":0}
{"ts":"2026-08-02T02:00:00Z","op":"add-def","module":"m3","def":"c","wall_ms":400,"payload_bytes":10,"module_bytes":300000,"accepted":false,"reject_reason":"parse","recompile_ms":null,"retry_seq":1}
JSONL

cat >"$scratch/expected" <<'EXPECTED'
SLOWEST_OP_SHAPES
op	module_size_bucket	n	p50_ms	p95_ms
add-def	ge256k	2	300	400
add-def	16k-64k	2	100	200
set-body	lt16k	3	20	30
show	unknown	1	5	5

REJECT_RATE
op	reject_reason	attempts	rejects	reject_rate
add-def	compile	4	2	50.0%
add-def	parse	4	1	25.0%
set-body	missing target	3	1	33.3%

RETRY_HEAVY_DEFS
module	def	attempts	retries	max_retry_seq	total_wall_ms
m1	a	3	2	2	60
m3	c	2	1	1	700
m2	b	2	1	1	300

DAILY_TREND
day	attempts	accepted	rejects	reject_rate	p50_ms	p95_ms
2026-08-01	6	4	2	33.3%	20	200
2026-08-02	2	0	2	100.0%	300	400

EXPECTED

bin/beagle-store-graph-ops-report "$scratch/fixture.jsonl" >"$scratch/actual"
diff -u "$scratch/expected" "$scratch/actual"
printf 'graph-ops-report-replay: PASS — exact p50/p95, rejects, retries, daily rows\n'
