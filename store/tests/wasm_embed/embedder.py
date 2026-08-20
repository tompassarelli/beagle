# SPDX-License-Identifier: MIT OR Apache-2.0
"""External wasm embedder for store's named-import host regime.

Instantiates lib/libstore.wasm with wasmtime and supplies all nine store_host_v1
imports as host functions. The STORELOG lives in this process as a bytearray:
the guest gets no preopened directory, no realtime clock, and no allocator of
its own for responses. WASI is answered only where the Beagle shim genuinely
reaches it (monotonic clock, empty environment); every other WASI import is a
counting ENOSYS stub, so any reliance on one is measured, not assumed. Prints
the same transcript as tests/wasm_embed/packets_driver.c.
"""
import struct
import sys

from wasmtime import Engine, FuncType, Linker, Module, Store, ValType

I32 = ValType.i32()
I64 = ValType.i64()

FIXED_EPOCH_MS = 1700000000000
FIXED_MONOTONIC_NS = 1000000000
PAGE_BYTES = 65536
ARENA_PAGES = 256
OPTIONS_SIZE = 32  # store_open_options_v1 on wasm32
ERROR_SIZE = 516  # store_error
BUFFER_SIZE = 16  # store_buffer
ENOSYS = 52

WASI_PREVIEW1 = [
    ("args_get", [I32, I32]),
    ("args_sizes_get", [I32, I32]),
    ("environ_get", [I32, I32]),
    ("environ_sizes_get", [I32, I32]),
    ("clock_time_get", [I32, I64, I32]),
    ("fd_close", [I32]),
    ("fd_fdstat_get", [I32, I32]),
    ("fd_filestat_get", [I32, I32]),
    ("fd_filestat_set_size", [I32, I64]),
    ("fd_pread", [I32, I32, I32, I64, I32]),
    ("fd_prestat_get", [I32, I32]),
    ("fd_prestat_dir_name", [I32, I32, I32]),
    ("fd_read", [I32, I32, I32, I32]),
    ("fd_seek", [I32, I64, I32, I32]),
    ("fd_sync", [I32]),
    ("fd_write", [I32, I32, I32, I32]),
    ("path_open", [I32, I32, I32, I32, I32, I64, I64, I32, I32]),
    ("proc_exit", [I32]),
    ("random_get", [I32, I32]),
]


class HostLog:
    """The STORELOG and the snapshot image, both held on the host side.

    One storage context per object: the import host passes 0 for the log and 1
    for the image, so the same seven storage imports serve both.
    """

    def __init__(self):
        self.bytes = bytearray()
        self.image = bytearray()
        self.calls = {}

    def object_for(self, context):
        return self.image if context == 1 else self.bytes

    def tick(self, name):
        self.calls[name] = self.calls.get(name, 0) + 1

    def install(self, linker):
        def clock_milliseconds(caller, context, out_ptr):
            self.tick("clock_milliseconds")
            caller.get("memory").write(
                caller, struct.pack("<q", FIXED_EPOCH_MS), out_ptr
            )
            return 0

        def storage_size(caller, context, out_ptr):
            self.tick("storage_size")
            caller.get("memory").write(
                caller, struct.pack("<Q", len(self.object_for(context))), out_ptr
            )
            return 0

        def storage_read(caller, context, offset, destination, length):
            self.tick("storage_read")
            target = self.object_for(context)
            if offset + length > len(target):
                return 1
            caller.get("memory").write(
                caller, bytes(target[offset : offset + length]), destination
            )
            return 0

        def storage_truncate(caller, context, length):
            self.tick("storage_truncate")
            target = self.object_for(context)
            if length > len(target):
                return 1
            del target[length:]
            return 0

        def storage_append(caller, context, pointer, length):
            self.tick("storage_append")
            memory = caller.get("memory")
            target = self.object_for(context)
            target += bytes(memory.read(caller, pointer, pointer + length))
            return 0

        def storage_sync(caller, context):
            self.tick("storage_sync")
            return 0

        def storage_close(caller, context):
            self.tick("storage_close")
            return 0

        hooks = [
            ("clock_milliseconds", [I32, I32], clock_milliseconds),
            ("storage_size", [I32, I32], storage_size),
            ("storage_read", [I32, I64, I32, I32], storage_read),
            ("storage_truncate", [I32, I64], storage_truncate),
            ("storage_append", [I32, I32, I32], storage_append),
            ("storage_sync", [I32], storage_sync),
            ("storage_close", [I32], storage_close),
        ]
        for name, parameters, hook in hooks:
            linker.define_func(
                "store_host_v1",
                name,
                FuncType(parameters, [I32]),
                hook,
                access_caller=True,
            )


class HostArena:
    """Response memory the embedder owns, inside guest linear memory.

    A host function cannot hand back a pointer into the host's own heap, so an
    allocate import partitions the guest's memory instead. This one never
    reuses a freed block; an embedder wanting reuse re-enters store_wasm_alloc.
    """

    def __init__(self, calls):
        self.base = 0
        self.next = 0
        self.end = 0
        self.calls = calls

    def claim(self, memory, store):
        pages_before = memory.grow(store, ARENA_PAGES)
        self.base = pages_before * PAGE_BYTES
        self.next = self.base
        self.end = self.base + ARENA_PAGES * PAGE_BYTES

    def install(self, linker):
        def allocate(caller, context, size):
            self.calls["allocate"] = self.calls.get("allocate", 0) + 1
            address = (self.next + 15) & ~15
            if address + size > self.end:
                return 0  # NULL: store must surface BEAGLE_STORE_OUT_OF_MEMORY
            self.next = address + size
            return address

        def deallocate(caller, context, pointer):
            self.calls["deallocate"] = self.calls.get("deallocate", 0) + 1

        linker.define_func(
            "store_host_v1", "allocate", FuncType([I32, I32], [I32]), allocate,
            access_caller=True,
        )
        linker.define_func(
            "store_host_v1", "deallocate", FuncType([I32, I32], []), deallocate,
            access_caller=True,
        )


def install_wasi(linker, refused, served):
    """WASI refuses everywhere except the three imports the engine reaches.

    The Beagle shim's monotonic clock and getenv primitives have no
    store_host_v1 field, so clock_time_get and the environ pair are the
    capabilities this regime still takes from WASI: refusing the clock aborts
    a query, and refusing environ_sizes_get makes wasi-libc _Exit(71) out of
    its own environment bootstrap. An empty environment is a legal answer.
    Everything else is counted and refused, so any reliance shows as a count.
    """

    def tick(name):
        served[name] = served.get(name, 0) + 1

    def clock_time_get(caller, clock_id, precision, out_pointer):
        tick("clock_time_get")
        caller.get("memory").write(
            caller, struct.pack("<Q", FIXED_MONOTONIC_NS), out_pointer
        )
        return 0

    def environ_sizes_get(caller, count_pointer, size_pointer):
        tick("environ_sizes_get")
        memory = caller.get("memory")
        memory.write(caller, struct.pack("<I", 0), count_pointer)
        memory.write(caller, struct.pack("<I", 0), size_pointer)
        return 0

    def environ_get(caller, environ_pointer, buffer_pointer):
        tick("environ_get")
        return 0

    supplied = {
        "clock_time_get": clock_time_get,
        "environ_sizes_get": environ_sizes_get,
        "environ_get": environ_get,
    }

    def make(name):
        def stub(caller, *arguments):
            refused[name] = refused.get(name, 0) + 1
            if name == "proc_exit":
                raise RuntimeError("guest called proc_exit(%d)" % arguments[0])
            return ENOSYS

        return stub

    for name, parameters in WASI_PREVIEW1:
        results = [] if name == "proc_exit" else [I32]
        hook = supplied.get(name, None) or make(name)
        linker.define_func(
            "wasi_snapshot_preview1",
            name,
            FuncType(parameters, results),
            hook,
            access_caller=True,
        )


class Guest:
    def __init__(self, engine, module, log, refused, served):
        self.store = Store(engine)
        self.arena = HostArena(log.calls)
        linker = Linker(engine)
        log.install(linker)
        self.arena.install(linker)
        install_wasi(linker, refused, served)
        instance = linker.instantiate(self.store, module)
        self.exports = instance.exports(self.store)
        self.memory = self.exports["memory"]
        self.exports["_initialize"](self.store)
        self.arena.claim(self.memory, self.store)

    def call(self, name, *arguments):
        return self.exports[name](self.store, *arguments)

    def alloc(self, size):
        address = self.call("store_wasm_alloc", size)
        assert address, "store_wasm_alloc returned NULL"
        self.memory.write(self.store, bytes(size), address)
        return address

    def free(self, address):
        self.call("store_wasm_free", address)

    def write(self, address, payload):
        self.memory.write(self.store, payload, address)

    def read(self, address, length):
        return bytes(self.memory.read(self.store, address, address + length))

    def read_u32(self, address):
        return struct.unpack("<I", self.read(address, 4))[0]

    def read_message(self, address):
        raw = self.read(address, ERROR_SIZE - 4)
        end = raw.find(b"\0")
        return raw[: end if end >= 0 else len(raw)].decode(errors="replace")

    def put_cstring(self, text):
        raw = text.encode() + b"\0"
        address = self.alloc(len(raw))
        self.write(address, raw)
        return address

    def open_options(self, space_id, log_label):
        space = self.put_cstring(space_id)
        label = self.put_cstring(log_label)
        address = self.alloc(OPTIONS_SIZE)
        # host = 0: the named imports are selected by a NULL host table.
        # The trailing pad + u64 is memory_budget_bytes: zero names no budget.
        self.write(
            address,
            struct.pack(
                "<IIIIIIQ", 1, OPTIONS_SIZE, space, label, 0, 0, 0
            ),
        )
        return address


def read_manifest(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.split()
            if len(fields) >= 3:
                rows.append((fields[0], fields[1], int(fields[2])))
    return rows


def run_pass(guest, label, packets_dir, manifest_path, space_id, out):
    entry_calls = {"t": "store_transact", "s": "store_snapshot"}
    options = guest.open_options(space_id, "in-memory")
    database_out = guest.alloc(4)
    error = guest.alloc(ERROR_SIZE)
    status = guest.call("store_open", options, database_out, error)
    out.write('%s %d "%s"\n' % (label, status, guest.read_message(error + 4)))
    if status != 0:
        return 1
    database = guest.read_u32(database_out)

    failures = 0
    for entry, name, declared in read_manifest(manifest_path):
        with open("%s/%s" % (packets_dir, name), "rb") as handle:
            request = handle.read()
        if len(request) != declared:
            out.write("packet %s READ-MISMATCH\n" % name)
            failures += 1
            continue
        request_ptr = guest.alloc(len(request))
        guest.write(request_ptr, request)
        slice_ptr = guest.alloc(8)
        guest.write(slice_ptr, struct.pack("<II", request_ptr, len(request)))
        buffer_ptr = guest.alloc(BUFFER_SIZE)
        error = guest.alloc(ERROR_SIZE)
        status = guest.call(
            entry_calls.get(entry, "store_query"),
            database,
            slice_ptr,
            buffer_ptr,
            error,
        )
        data, length, _context, _release = struct.unpack(
            "<IIII", guest.read(buffer_ptr, BUFFER_SIZE)
        )
        response = guest.read(data, length) if length else b""
        out.write("packet %s %d %s\n" % (name, status, response.hex()))
        if status != 0:
            failures += 1
        guest.call("store_buffer_release", buffer_ptr)
        if struct.unpack("<IIII", guest.read(buffer_ptr, BUFFER_SIZE)) != (
            0,
            0,
            0,
            0,
        ):
            out.write("packet %s RELEASE-DID-NOT-CLEAR\n" % name)
            failures += 1
        guest.free(request_ptr)

    error = guest.alloc(ERROR_SIZE)
    status = guest.call("store_close", database, error)
    out.write('close %d "%s"\n' % (status, guest.read_message(error + 4)))
    return 1 if (status != 0 or failures) else 0


def main():
    if len(sys.argv) < 9:
        sys.stderr.write(
            "usage: embedder.py MODULE PACKETS MANIFEST REOPEN-MANIFEST "
            "IMAGE-MANIFEST LOG-OUT TALLY-OUT SPACE\n"
        )
        return 2
    (
        module_path,
        packets_dir,
        manifest_path,
        reopen_manifest_path,
        image_manifest_path,
        log_path,
        tally_path,
        space_id,
    ) = sys.argv[1:9]

    engine = Engine()
    module = Module.from_file(engine, module_path)
    log = HostLog()
    refused = {}
    served = {}

    failures = run_pass(
        Guest(engine, module, log, refused, served),
        "open",
        packets_dir,
        manifest_path,
        space_id,
        sys.stdout,
    )
    # A fresh instance over the retained host bytes: the reopen replays the
    # log through the same imports, with no guest state carried over.
    failures += run_pass(
        Guest(engine, module, log, refused, served),
        "reopen",
        packets_dir,
        reopen_manifest_path,
        space_id,
        sys.stdout,
    )

    # A third instance over the retained host bytes: the image object now
    # holds a checkpoint, so this open takes the snapshot route plus the tail.
    failures += run_pass(
        Guest(engine, module, log, refused, served),
        "image",
        packets_dir,
        image_manifest_path,
        space_id,
        sys.stdout,
    )

    with open(log_path, "wb") as handle:
        handle.write(bytes(log.bytes))
    with open(tally_path, "w", encoding="utf-8") as handle:
        for name, count in sorted(refused.items()):
            handle.write("wasi %s %d\n" % (name, count))
        for name, count in sorted(served.items()):
            handle.write("served %s %d\n" % (name, count))
        for name, count in sorted(log.calls.items()):
            handle.write("host %s %d\n" % (name, count))
    sys.stdout.write("log %d\n" % len(log.bytes))
    sys.stdout.write("image %d\n" % len(log.image))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
