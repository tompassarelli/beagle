#!/usr/bin/env python3
"""SQLite triple-store adapter for the durable sole-writer benchmark."""

import json
import sqlite3
import statistics
import sys
import tempfile
import threading
import time
from pathlib import Path


def elapsed_ms(start_ns: int) -> float:
    return (time.perf_counter_ns() - start_ns) / 1_000_000


def corpus_fact(tx: int) -> tuple[str, str, str]:
    subject = (tx - 1) // 3
    slot = (tx - 1) % 3
    if slot == 0:
        predicate, value = "kind", "thread"
    elif slot == 1:
        predicate, value = "title", f"title-{subject}"
    else:
        predicate, value = "owner", f"@owner-{subject % 32}"
    return f"@corpus-{subject}", predicate, value


def configure(connection: sqlite3.Connection) -> None:
    connection.execute("PRAGMA busy_timeout=120000")
    connection.execute("PRAGMA synchronous=FULL")


def read_join(connection: sqlite3.Connection) -> list[tuple[str, str]]:
    return connection.execute(
        """
        SELECT kind.subject, title.object
          FROM triples AS kind
          JOIN triples AS title ON title.subject = kind.subject
         WHERE kind.predicate = 'kind'
           AND kind.object = 'thread'
           AND title.predicate = 'title'
        """
    ).fetchall()


def durable_insert(
    connection: sqlite3.Connection, subject: str, predicate: str, value: str
) -> None:
    connection.execute("BEGIN IMMEDIATE")
    connection.execute(
        "INSERT INTO triples(subject, predicate, object) VALUES (?, ?, ?)",
        (subject, predicate, value),
    )
    connection.execute("COMMIT")


def main() -> int:
    corpus_triples = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    run_id = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    if corpus_triples <= 0 or corpus_triples % 3:
        raise ValueError("corpus size must be a positive multiple of 3")
    expected_rows = corpus_triples // 3

    errors = 0
    with tempfile.TemporaryDirectory(prefix="store-in-class-sqlite-") as scratch:
        database = Path(scratch) / "triples.sqlite"
        seed = sqlite3.connect(database, isolation_level=None)
        seed.execute("PRAGMA journal_mode=WAL")
        seed.execute("PRAGMA synchronous=FULL")
        seed.execute(
            """
            CREATE TABLE triples(
              subject TEXT NOT NULL,
              predicate TEXT NOT NULL,
              object TEXT NOT NULL,
              PRIMARY KEY(subject, predicate, object)
            ) WITHOUT ROWID
            """
        )
        seed.execute(
            "CREATE INDEX triples_pos ON triples(predicate, object, subject)"
        )
        seed.execute("BEGIN IMMEDIATE")
        seed.executemany(
            "INSERT INTO triples(subject, predicate, object) VALUES (?, ?, ?)",
            (corpus_fact(tx) for tx in range(1, corpus_triples + 1)),
        )
        seed.execute("COMMIT")
        seed.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        seed.close()

        boot_start = time.perf_counter_ns()
        writer = sqlite3.connect(
            database, isolation_level=None, check_same_thread=False
        )
        configure(writer)
        writer.execute("SELECT 1").fetchone()
        boot_ms = elapsed_ms(boot_start)

        cold_reader = sqlite3.connect(database, isolation_level=None)
        configure(cold_reader)
        cold_start = time.perf_counter_ns()
        cold_rows = read_join(cold_reader)
        cold_ms = elapsed_ms(cold_start)
        if len(cold_rows) != expected_rows:
            errors += 1

        for i in range(30):
            durable_insert(writer, f"@warm-{i}", "bench_value", f"warm-{i}")
        for _ in range(10):
            if len(read_join(cold_reader)) != expected_rows:
                errors += 1

        stop = threading.Event()
        read_ops = 0
        read_errors = 0

        def concurrent_reader() -> None:
            nonlocal read_ops, read_errors
            connection = sqlite3.connect(database, isolation_level=None)
            configure(connection)
            while not stop.is_set():
                if len(read_join(connection)) != expected_rows:
                    read_errors += 1
                read_ops += 1
            connection.close()

        reader_thread = threading.Thread(target=concurrent_reader)
        reader_thread.start()
        write_start = time.perf_counter_ns()
        for i in range(1200):
            durable_insert(
                writer,
                f"@sustained-{run_id}-{i}",
                "bench_value",
                f"value-{i}",
            )
        write_ms = elapsed_ms(write_start)
        stop.set()
        reader_thread.join()
        if read_ops == 0:
            read_errors += 1
        errors += read_errors

        mixed_read_latencies: list[float] = []
        mixed_start = time.perf_counter_ns()
        for i in range(40):
            durable_insert(
                writer, f"@mixed-{run_id}-{i}", "bench_value", f"value-{i}"
            )
            for _ in range(3):
                read_start = time.perf_counter_ns()
                rows = read_join(cold_reader)
                mixed_read_latencies.append(elapsed_ms(read_start))
                if len(rows) != expected_rows:
                    errors += 1
        mixed_ms = elapsed_ms(mixed_start)

        row = {
            "adapter": "sqlite",
            "run": run_id,
            "corpus-triples": corpus_triples,
            "boot-to-serving-ms": boot_ms,
            "cold-start-query-ms": cold_ms,
            "cold-query-rows": len(cold_rows),
            "write-under-read-ops-s": 1200.0 / (write_ms / 1000.0),
            "concurrent-read-ops": read_ops,
            "mixed-ops-s": 160.0 / (mixed_ms / 1000.0),
            "mixed-read-p50-ms": statistics.median(mixed_read_latencies),
            "errors": errors,
        }
        writer.close()
        cold_reader.close()
        print("BENCHROW", json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
